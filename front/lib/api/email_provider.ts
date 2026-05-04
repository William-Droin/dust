import nodemailer from "nodemailer";

import config from "@app/lib/api/config";
import logger from "@app/logger/logger";
import { isDevelopment } from "@app/types";

export type EmailAddress = {
  name?: string;
  email: string;
};

export type SendEmailArgs = {
  to: string;
  from: EmailAddress;
  replyTo?: string;
  subject: string;
  html: string;
  text?: string;
};

let smtpTransport: nodemailer.Transporter | null = null;

function getSmtpTransport(): nodemailer.Transporter {
  if (smtpTransport) {
    return smtpTransport;
  }

  const host = config.getSmtpHost();
  const port = config.getSmtpPort();
  const secure = config.getSmtpSecure();
  const user = config.getSmtpUser();
  const pass = config.getSmtpPassword();

  smtpTransport = nodemailer.createTransport({
    host,
    port,
    secure,
    auth: user && pass ? { user, pass } : undefined,
  });

  return smtpTransport;
}

function formatFrom(from: EmailAddress): string {
  return from.name ? `${from.name} <${from.email}>` : from.email;
}

/**
 * Send an email using the configured provider.
 *
 * For self-hosting, set `EMAIL_PROVIDER=smtp` and configure SMTP_* variables.
 *
 * Gmail SMTP notes:
 * - Use an App Password (not your normal password).
 * - host: smtp.gmail.com
 * - port: 587
 * - secure: false (STARTTLS)
 */
export async function sendEmailRaw(args: SendEmailArgs): Promise<void> {
  // In dev we want to make sure we don't send emails to real users.
  if (isDevelopment() && !args.to.endsWith("@dust.tt")) {
    logger.error(
      { to: args.to, subject: args.subject },
      "Prevented sending email in development mode to an external email."
    );
    return;
  }

  const provider = config.getEmailProvider();
  if (provider === "smtp") {
    const transporter = getSmtpTransport();
    await transporter.sendMail({
      to: args.to,
      from: formatFrom(args.from),
      replyTo: args.replyTo,
      subject: args.subject,
      html: args.html,
      text: args.text,
    });
    logger.info({ to: args.to, subject: args.subject }, "Email sent (SMTP)");
    return;
  }

  // Keep SendGrid as an optional provider for backward compatibility.
  const sgMail = (await import("@sendgrid/mail")).default;
  const apiKey = config.getOptionalSendgridApiKey();
  if (!apiKey) {
    throw new Error(
      "EMAIL_PROVIDER=sendgrid requires SENDGRID_API_KEY to be set."
    );
  }
  sgMail.setApiKey(apiKey);
  await sgMail.send({
    to: args.to,
    from: { name: args.from.name, email: args.from.email },
    replyTo: args.replyTo,
    subject: args.subject,
    html: args.html,
    text: args.text,
  });
  logger.info({ to: args.to, subject: args.subject }, "Email sent (SendGrid)");
}
