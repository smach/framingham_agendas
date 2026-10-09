# test_email.R
#
# Sends a single test email using the same SMTP settings as the real hearing
# notifications. Use it to check your email secrets without waiting for a new
# hearing in a monitored district.
#
# On GitHub: Actions tab > "Send Test Email" > "Run workflow".
# Locally: set the SMTP_* and EMAIL_* environment variables (for example in
# .Renviron), then run  Rscript test_email.R
#
# Exits with an error status if sending fails, so the workflow run shows red.

source("email_config.R")

# Wrapping everything in tryCatch() lets us print a helpful message and exit
# with a failure code instead of R's default error output.
result <- tryCatch(
  {
    # 1. Confirm every setting is present (prints set/MISSING for each)
    check_email_settings()

    # 2. Send a short test message. tries = 1 means no retries, so a bad
    #    password or host fails immediately with the server's real error.
    email <- emayili::envelope(
      to = get_email_setting("EMAIL_TO"),
      from = get_email_setting("EMAIL_FROM"),
      subject = "Framingham agendas: test email",
      text = paste0(
        "This is a test email from the framingham_agendas project.\n\n",
        "If you're reading it, the SMTP settings work and hearing ",
        "notifications will be delivered.\n\n",
        "Sent: ", format(Sys.time(), tz = "America/New_York", usetz = TRUE), "\n"
      )
    )
    send_with_retries(email, tries = 1)

    message("Test email sent. Check the inbox (and spam folder) for EMAIL_TO.")
    "ok"
  },
  error = function(e) describe_email_error(e)
)

if (!identical(result, "ok")) {
  report_email_failure(result)
  message(
    "\nCommon causes:\n",
    "  - Gmail: SMTP_PASSWORD must be a 16-character App Password, not your\n",
    "    regular password (requires 2-Step Verification on the account).\n",
    "  - SMTP_HOST should be just the host name, e.g. smtp.gmail.com.\n",
    "  - SMTP_PORT is usually 587 (or 465).\n",
    "  - SMTP_USERNAME is usually your full email address."
  )
  quit(status = 1)
}
