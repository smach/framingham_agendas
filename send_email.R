# Step 4: Send email notification for new hearings in districts 1, 2, 3, 4, or 6
  districts_to_notify <- c("1", "2", "3", "4")
  new_items_to_notify <- hearings_with_districts %>%
    filter(District %in% districts_to_notify)

  if (nrow(new_items_to_notify) > 0) {
    # Create email body
    districts_with_items <- unique(new_items_to_notify$District)
    email_body <- paste0(
      "New hearing items found in District",
      if(length(districts_with_items) > 1) "s" else "",
      " ",
      paste(districts_with_items, collapse = ", "),
      ":\n\n"
    )

    for (i in 1:nrow(new_items_to_notify)) {
      item <- new_items_to_notify[i, ]
      email_body <- paste0(
        email_body,
        "District: ", item$District, "\n",
        "Date: ", item$Date, "\n",
        "Board: ", item$Board, "\n",
        "Description: ", item$description, "\n",
        "Address: ", item$address, "\n",
        "URL: ", item$URL, "\n\n",
        "---\n\n"
      )
    }

    # Set up SMTP server (credentials from environment variables)
    smtp <- emayili::server(
      host = Sys.getenv("SMTP_HOST"),
      port = as.numeric(Sys.getenv("SMTP_PORT")),
      username = Sys.getenv("SMTP_USERNAME"),
      password = Sys.getenv("SMTP_PASSWORD")
    )

    # Create and send email
    email <- emayili::envelope(
      to = Sys.getenv("EMAIL_TO"),
      from = Sys.getenv("EMAIL_FROM"),
      subject = paste0("New Framingham Hearings - ", nrow(new_items_to_notify), " items in Districts ", paste(unique(new_items_to_notify$District), collapse = ", ")),
      text = email_body
    )

    smtp(email, verbose = FALSE)
    message("Email sent: ", nrow(new_items_to_notify), " new hearing items in monitored districts")
  } else {
    message("No new hearing items in monitored districts (1, 2, 3, 4, 6)")
  }
