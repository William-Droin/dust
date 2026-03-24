use crate::providers::chat_messages::ChatMessage;
use crate::providers::embedder::{Embedder, EmbedderVector};
use crate::providers::llm::ChatFunction;
use crate::providers::llm::TokenizerSingleton;
use crate::providers::llm::{LLMChatGeneration, LLMGeneration, LLM};
use crate::providers::provider::{Provider, ProviderID};
use crate::providers::tiktoken::tiktoken::{batch_tokenize_async, decode_async, encode_async, o200k_base_singleton, CoreBPE};
use crate::run::Credentials;
use crate::types::tokenizer::{TiktokenTokenizerBase, TokenizerConfig};
use crate::utils;

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use hyper::body::Buf;
use hyper::Uri;
use parking_lot::RwLock;
use serde_json::Value;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::sync::Arc;
use std::io::prelude::*;
use std::time::Duration;
use tokio::sync::mpsc::UnboundedSender;
use tokio::time::timeout;

use super::helpers::strip_tools_from_chat_history;
use super::openai_compatible_helpers::{
    openai_compatible_chat_completion, TransformSystemMessages,
};

// ModelIds that support tools
const MODEL_IDS_WITH_TOOLS_SUPPORT: &[&str] = &["openai/gpt-oss-120b"];

// Embedder model ids supported via OpenRouter (OpenAI-compatible embeddings endpoint).
// We keep the list explicit so misconfigurations fail fast.
const GHS_EMBEDDER_MODELS: &[&str] = &["qwen/qwen3-embedding-4b"];

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct OpenAICompatibleEmbedding {
    pub embedding: Vec<f64>,
    pub index: u64,
    pub object: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct OpenAICompatibleEmbeddings {
    pub model: String,
    pub object: String,
    pub data: Vec<OpenAICompatibleEmbedding>,
}

pub struct GhsEmbedder {
    id: String,
    api_key: Option<String>,
}

impl GhsEmbedder {
    pub fn new(id: String) -> Self {
        Self { id, api_key: None }
    }

    fn uri(&self) -> Result<Uri> {
        Ok(format!("https://openrouter.ai/api/v1/embeddings").parse::<Uri>()?)
    }

    fn tokenizer(&self) -> Arc<RwLock<CoreBPE>> {
        // We don't have a model-specific tokenizer for OpenRouter embeddings. We rely on the
        // o200k tokenizer (same as used for GhsLLM) which is good enough for splitting.
        o200k_base_singleton()
    }
}

#[async_trait]
impl Embedder for GhsEmbedder {
    fn id(&self) -> String {
        self.id.clone()
    }

    async fn initialize(&mut self, credentials: Credentials) -> Result<()> {
        if !GHS_EMBEDDER_MODELS.contains(&self.id.as_str()) {
            return Err(anyhow!(
                "Unexpected embedder model id (`{}`) for provider `ghs`",
                self.id
            ));
        }

        // Mirror OpenAI/Mistral approach: prefer a dedicated env var for core data sources, fall
        // back to passed creds or global env var for local dev.
        self.api_key = match std::env::var("CORE_DATA_SOURCES_GHS_API_KEY") {
            Ok(key) => Some(key),
            Err(_) => match credentials.get("GHS_API_KEY") {
                Some(api_key) => Some(api_key.clone()),
                None => match tokio::task::spawn_blocking(|| std::env::var("GHS_API_KEY")).await? {
                    Ok(key) => Some(key),
                    Err(_) => {
                        return Err(anyhow!(
                            "CORE_DATA_SOURCES_GHS_API_KEY or GHS_API_KEY must be set."
                        ));
                    }
                },
            },
        };

        Ok(())
    }

    fn context_size(&self) -> usize {
        // Conservative default. This is mostly used by the splitter; OpenRouter does not expose
        // a consistent context window for embeddings.
        8192
    }

    fn embedding_size(&self) -> usize {
        // OpenRouter doesn't guarantee dimensions in advance. We use the expected size for the
        // selected model; if it changes the error will appear at Qdrant insertion time.
        // Qwen3-embedding-4b is 2560 dims.
        2560
    }

    async fn encode(&self, text: &str) -> Result<Vec<usize>> {
        encode_async(self.tokenizer(), text).await
    }

    async fn decode(&self, tokens: Vec<usize>) -> Result<String> {
        decode_async(self.tokenizer(), tokens).await
    }

    async fn tokenize(&self, texts: Vec<String>) -> Result<Vec<Vec<(usize, String)>>> {
        batch_tokenize_async(self.tokenizer(), texts).await
    }

    async fn embed(&self, text: Vec<&str>, _extras: Option<Value>) -> Result<Vec<EmbedderVector>> {
        let api_key = match self.api_key.clone() {
            Some(key) => key,
            None => Err(anyhow!("GHS_API_KEY is not set."))?,
        };

        let body = json!({
            "input": text,
            "model": self.id,
        });

        // NOTE: OpenRouter recommends additional headers (HTTP-Referer, X-Title). We keep it
        // minimal here; users can configure at their reverse proxy if needed.
        let req = reqwest::Client::new()
            .post(self.uri()?.to_string())
            .header("Content-Type", "application/json")
            .header("Authorization", format!("Bearer {}", api_key))
            .json(&body);

        let res = match timeout(Duration::new(60, 0), req.send()).await {
            Ok(Ok(res)) => res,
            Ok(Err(e)) => Err(e)?,
            Err(_) => Err(anyhow!("Timeout sending request to OpenRouter after 60s"))?,
        };

        let body = match timeout(Duration::new(60, 0), res.bytes()).await {
            Ok(Ok(body)) => body,
            Ok(Err(e)) => Err(e)?,
            Err(_) => Err(anyhow!("Timeout reading response from OpenRouter after 60s"))?,
        };

        // `reqwest::Response::bytes()` returns `bytes::Bytes`. Converting it to a Vec is the
        // simplest/most robust way to pass it to serde_json without relying on the `Buf::reader()`
        // extension method (which can be provided by different `Buf` traits depending on versions).
        let b: Vec<u8> = body.to_vec();

        let embeddings: OpenAICompatibleEmbeddings = serde_json::from_slice(&b).map_err(|e| {
            anyhow!(
                "Failed parsing embeddings response from OpenRouter: err={} body={}",
                e,
                String::from_utf8_lossy(&b)
            )
        })?;

        if embeddings.data.is_empty() {
            return Err(anyhow!("No embeddings returned from OpenRouter"));
        }

        Ok(embeddings
            .data
            .into_iter()
            .map(|v| EmbedderVector {
                created: utils::now(),
                provider: ProviderID::Ghs.to_string(),
                model: self.id.clone(),
                vector: v.embedding,
            })
            .collect::<Vec<_>>())
    }
}

pub struct GhsLLM {
    id: String,
    api_key: Option<String>,
    tokenizer: Option<TokenizerSingleton>,
}

impl GhsLLM {
    pub fn new(id: String, tokenizer: Option<TokenizerSingleton>) -> Self {
        GhsLLM {
            id,
            api_key: None,
            tokenizer: tokenizer.or_else(|| {
                TokenizerSingleton::from_config(&TokenizerConfig::Tiktoken {
                    base: TiktokenTokenizerBase::O200kHarmony,
                })
            }),
        }
    }

    fn chat_uri(&self) -> Result<Uri> {
        Ok(format!("https://openrouter.ai/api/v1/chat/completions",).parse::<Uri>()?)
    }

    pub fn ghs_context_size(_model_id: &str) -> usize {
        // Default context size for GHS models
        128_000
    }
}

#[async_trait]
impl LLM for GhsLLM {
    fn id(&self) -> String {
        self.id.clone()
    }

    async fn initialize(&mut self, credentials: Credentials) -> Result<()> {
        match credentials.get("GHS_API_KEY") {
            Some(api_key) => {
                self.api_key = Some(api_key.clone());
            }
            None => match tokio::task::spawn_blocking(|| std::env::var("GHS_API_KEY")).await? {
                Ok(key) => {
                    self.api_key = Some(key);
                }
                Err(_) => Err(anyhow!(
                    "Credentials or environment variable `GHS_API_KEY` is not set."
                ))?,
            },
        }
        Ok(())
    }

    fn context_size(&self) -> usize {
        Self::ghs_context_size(self.id.as_str())
    }

    async fn encode(&self, text: &str) -> Result<Vec<usize>> {
        self.tokenizer
            .as_ref()
            .ok_or_else(|| anyhow!("Tokenizer not initialized"))?
            .encode(text)
            .await
    }

    async fn decode(&self, tokens: Vec<usize>) -> Result<String> {
        self.tokenizer
            .as_ref()
            .ok_or_else(|| anyhow!("Tokenizer not initialized"))?
            .decode(tokens)
            .await
    }

    async fn tokenize(&self, texts: Vec<String>) -> Result<Vec<Vec<(usize, String)>>> {
        self.tokenizer
            .as_ref()
            .ok_or_else(|| anyhow!("Tokenizer not initialized"))?
            .tokenize(texts)
            .await
    }

    async fn generate(
        &self,
        _prompt: &str,
        mut _max_tokens: Option<i32>,
        _temperature: f32,
        _n: usize,
        _stop: &Vec<String>,
        _frequency_penalty: Option<f32>,
        _presence_penalty: Option<f32>,
        _top_p: Option<f32>,
        _top_logprobs: Option<i32>,
        _extras: Option<Value>,
        _event_sender: Option<UnboundedSender<Value>>,
    ) -> Result<LLMGeneration> {
        Err(anyhow!("Not implemented."))
    }

    // API is openai-compatible.
    async fn chat(
        &self,
        messages: &Vec<ChatMessage>,
        functions: &Vec<ChatFunction>,
        function_call: Option<String>,
        temperature: f32,
        top_p: Option<f32>,
        n: usize,
        stop: &Vec<String>,
        max_tokens: Option<i32>,
        presence_penalty: Option<f32>,
        frequency_penalty: Option<f32>,
        logprobs: Option<bool>,
        top_logprobs: Option<i32>,
        _extras: Option<Value>,
        event_sender: Option<UnboundedSender<Value>>,
    ) -> Result<LLMChatGeneration> {
        let api_key = match self.api_key.clone() {
            Some(key) => key,
            None => Err(anyhow!("GHS_API_KEY is not set."))?,
        };

        openai_compatible_chat_completion(
            self.chat_uri()?,
            self.id.clone(),
            api_key,
            // Pre-process messages if model is one of the supported models.
            match MODEL_IDS_WITH_TOOLS_SUPPORT.contains(&self.id.as_str()) {
                false => Some(strip_tools_from_chat_history(messages)),
                true => None,
            }
            .as_ref()
            .map(|m| m.as_ref())
            .unwrap_or(messages),
            // Remove functions if model is one of the supported models.
            match MODEL_IDS_WITH_TOOLS_SUPPORT.contains(&self.id.as_str()) {
                false => None,
                true => Some(functions),
            }
            .as_ref()
            .map(|m| m.as_ref())
            .unwrap_or(functions),
            // Remove function call if model is one of the supported models.
            match MODEL_IDS_WITH_TOOLS_SUPPORT.contains(&self.id.as_str()) {
                false => None,
                true => function_call,
            },
            temperature,
            top_p,
            n,
            stop,
            max_tokens,
            presence_penalty,
            frequency_penalty,
            logprobs,
            top_logprobs,
            None,
            event_sender,
            false, // don't disable provider streaming
            TransformSystemMessages::Keep,
            "GHS".to_string(),
            true, // squash text contents (ghs doesn't support structured messages)
        )
        .await
    }
}

pub struct GhsProvider {}

impl GhsProvider {
    pub fn new() -> Self {
        GhsProvider {}
    }
}

#[async_trait]
impl Provider for GhsProvider {
    fn id(&self) -> ProviderID {
        ProviderID::Ghs
    }

    fn setup(&self) -> Result<()> {
        utils::info("Setting up GHS:");
        utils::info("");
        utils::info("To use GHS models, you must set the environment variable `GHS_API_KEY`.");
        utils::info("Your API key can be found at your GHS account dashboard.");
        utils::info("");
        utils::info("Once ready you can check your setup with `dust provider test ghs`");

        Ok(())
    }

    async fn test(&self) -> Result<()> {
        if !utils::confirm(
            "You are about to make a request for 1 token to `openai/gpt-oss-120b` on the GHS API.",
        )? {
            Err(anyhow!("User aborted GHS test."))?;
        }

        let tokenizer = TokenizerSingleton::from_config(&TokenizerConfig::Tiktoken {
            base: TiktokenTokenizerBase::O200kHarmony,
        });
        let mut llm = self.llm(String::from("openai/gpt-oss-120b"), tokenizer);
        llm.initialize(Credentials::new()).await?;

        let _ = llm
            .generate(
                "Hello 😊",
                Some(1),
                0.7,
                1,
                &vec![],
                None,
                None,
                None,
                None,
                None,
                None,
            )
            .await?;

        utils::done("Test successfully completed! GHS is ready to use.");

        Ok(())
    }

    fn llm(&self, id: String, tokenizer: Option<TokenizerSingleton>) -> Box<dyn LLM + Sync + Send> {
        Box::new(GhsLLM::new(id, tokenizer))
    }

    fn embedder(&self, id: String) -> Box<dyn Embedder + Sync + Send> {
        Box::new(GhsEmbedder::new(id))
    }
}
