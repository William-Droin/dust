import { createContext, useContext } from "react";

import type {
  VirtuosoMessage,
  VirtuosoMessageListContext,
} from "@app/components/assistant/conversation/types";

export type ConversationListMethods = {
  data: {
    get: () => VirtuosoMessage[];
    set: (items: VirtuosoMessage[]) => void;
    append: (items: VirtuosoMessage[]) => void;
    prepend: (items: VirtuosoMessage[]) => void;
    map: (mapper: (item: VirtuosoMessage) => VirtuosoMessage) => void;
    find: (predicate: (item: VirtuosoMessage) => boolean) =>
      | VirtuosoMessage
      | undefined;
  };
  scrollToItem: (options: {
    index: number | "LAST";
    align?: "start" | "end" | "center";
    behavior?: ScrollBehavior;
  }) => void;
  isAtBottom: boolean;
  context: VirtuosoMessageListContext;
};

const ConversationListContext = createContext<ConversationListMethods | null>(
  null
);

export const ConversationListProvider = ConversationListContext.Provider;

export const useConversationListMethods = () => {
  const methods = useContext(ConversationListContext);
  if (!methods) {
    throw new Error(
      "useConversationListMethods must be used within ConversationListProvider"
    );
  }
  return methods;
};