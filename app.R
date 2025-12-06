# Framingham Hearings Dashboard - Shiny App
library(shiny)
library(dplyr)
library(DT)
library(lubridate)
library(leaflet)
library(sf)
library(htmltools)
library(bslib)

# Load data
hearings <- readRDS("hearings_with_districts.Rds")

# Clean hearings data
hearings_clean <- hearings %>%
  mutate(
    District = as.character(District),
    District = if_else(is.na(District), "Unknown", District),
    Date = as.Date(Date),
    Link = paste0('<a href="', URL, '" target="_blank">View Agenda</a>')
  ) %>%
  select(Date, District, Board, description, address, Link) %>%
  arrange(desc(Date))

# Load district shapefile
districts_sf <- st_read("gis/framingham_districts.shp", quiet = TRUE) %>%
  mutate(District = as.character(District))

# Count hearings by district
hearing_counts <- hearings_clean %>%
  filter(District != "Unknown") %>%
  count(District, name = "hearing_count")

# Join counts to shapefile
districts_sf <- districts_sf %>%
  left_join(hearing_counts, by = "District") %>%
  mutate(hearing_count = if_else(is.na(hearing_count), 0L, hearing_count))

# Transform to WGS84 for leaflet
districts_wgs84 <- st_transform(districts_sf, 4326)

# Define UI
ui <- page_navbar(
  title = "Framingham Board of License Commissioners and Planning Board Agenda Data",
  theme = bs_theme(
    version = 5,
    bg = "#ffffff",
    fg = "#2c3e50",
    primary = "#2980b9",
    base_font = font_google("Open Sans"),
    heading_font = font_google("Montserrat")
  ),

  nav_panel(
    "Dashboard",

    # Header section with info
    layout_columns(
      col_widths = 12,
      div(
        style = "background: #f0f7fb; border-left: 4px solid #2980b9; padding: 1.25rem 1.5rem; margin-bottom: 1.5rem; border-radius: 6px;",
        p(style = "margin-bottom: 0.75rem; color: #2c3e50; font-size: 1rem;",
          "This dashboard shows scheduled public hearings extracted from Framingham Board of License Commissioners and Planning Board agendas, geocoded to city council districts."),
        p(style = "margin: 0; color: #5a6c7d; font-size: 0.9rem;",
          tags$strong("Date range: "), format(min(hearings_clean$Date, na.rm = TRUE), '%B %d, %Y'), " - ",
          format(max(hearings_clean$Date, na.rm = TRUE), '%B %d, %Y'), " | ",
          tags$strong("Last Updated: "), format(Sys.time(), '%B %d, %Y at %I:%M %p'), " | ",
          tags$strong("Total Hearings: "), nrow(hearings_clean)
        )
      )
    ),

    # Main content: Map and Table side by side
    div(
      style = "display: flex; flex-wrap: wrap; gap: 1rem; margin-bottom: 2rem;",

      # Left side: Map and Filters
      div(
        style = "flex: 0 0 40%; min-width: 350px;",
        # Map card
        card(
          card_header("Interactive District Map"),
          card_body(
            style = "padding: 0.75rem;",
            p("Click a district to filter the table. Click a second time to clear.",
              style = "color: #6c757d; font-size: 0.85rem; margin: 0 0 0.75rem 0;"),
            leafletOutput("map", height = "450px")
          )
        ),

        # Filter controls below map
        card(
          style = "margin-top: 1rem;",
          card_header("Filters"),
          card_body(
            style = "padding: 1rem;",
            actionButton("clear_filter", "Clear All Filters",
                        class = "btn-primary w-100 mb-3",
                        style = "font-size: 0.9rem; padding: 0.5rem;",
                        icon = icon("refresh")),
            selectInput("district_filter",
                       "District:",
                       choices = c("All" = "all", sort(unique(hearings_clean$District))),
                       selected = "all",
                       multiple = FALSE),
            selectInput("board_filter",
                       "Board:",
                       choices = c("All" = "all", unique(hearings_clean$Board)),
                       selected = "all",
                       multiple = FALSE),
            dateRangeInput("date_filter",
                          "Date Range:",
                          start = min(hearings_clean$Date, na.rm = TRUE),
                          end = max(hearings_clean$Date, na.rm = TRUE),
                          min = min(hearings_clean$Date, na.rm = TRUE),
                          max = max(hearings_clean$Date, na.rm = TRUE)),
            div(
              style = "margin-top: 1rem; padding: 0.75rem; background: #f8f9fa; border-radius: 4px; font-size: 0.85rem;",
              tags$strong("Selected: "), textOutput("selected_district", inline = TRUE)
            )
          )
        )
      ),

      # Right side: Table
      div(
        style = "flex: 1 1 55%; min-width: 400px;",
        card(
          card_header("Data on Scheduled Hearings"),
          card_body(
            style = "padding: 0.75rem; min-height: 600px;",
            p("Use the map/filters or search below to explore data about scheduled hearings.",
              style = "color: #6c757d; font-size: 0.85rem; margin: 0 0 0.75rem 0;"),
            div(style = "overflow-y: visible;",
              DTOutput("hearings_table")
            )
          )
        )
      )
    ),

    # Footer - outside of columns layout
    tags$footer(
      style = "text-align: center; padding: 1.5rem; color: #6c757d; font-size: 0.9rem; border-top: 2px solid #dee2e6; margin-top: 2rem; width: 100%; clear: both; display: block;",
      tags$em("Data source: "),
      tags$a("Framingham Meeting Agendas",
             href = "https://framinghamma.granicus.com/ViewPublisherRSS.php?view_id=1&mode=agendas",
             target = "_blank",
             style = "color: #2980b9; font-weight: 500;")
    )
  )
)

# Define server logic
server <- function(input, output, session) {

  # Reactive value to store selected district from map click
  selected_district <- reactiveVal(NULL)

  # Create color palette
  pal <- colorNumeric(
    palette = c("#e8f4f8", "#a8d5e2", "#2980b9"),
    domain = districts_wgs84$hearing_count
  )

  # Render the map
  output$map <- renderLeaflet({
    leaflet(districts_wgs84,
            options = leafletOptions(doubleClickZoom = TRUE)) %>%
      addProviderTiles(providers$CartoDB.Positron) %>%
      addPolygons(
        fillColor = ~pal(hearing_count),
        fillOpacity = 0.7,
        color = "#2c3e50",
        weight = 2,
        layerId = ~District,
        highlightOptions = highlightOptions(
          weight = 3,
          color = "#e74c3c",
          fillOpacity = 0.9,
          bringToFront = TRUE
        ),
        label = ~paste0("District ", District, ": ", hearing_count, " hearing(s)"),
        labelOptions = labelOptions(
          style = list("font-weight" = "bold", padding = "8px 12px"),
          textsize = "14px",
          direction = "auto"
        )
      ) %>%
      addLegend(
        position = "topright",
        pal = pal,
        values = ~hearing_count,
        title = "Number of<br/>Hearings",
        opacity = 0.9
      )
  })

  # Handle clicks on map background (outside districts) to clear selection
  observeEvent(input$map_click, {
    click <- input$map_click
    shape_click <- input$map_shape_click

    # If we have a map click but no shape click at the same time, clear filter
    if (!is.null(click) && is.null(shape_click$id)) {
      selected_district(NULL)
      last_click(NULL)
      updateSelectInput(session, "district_filter", selected = "all")
    }
  })

  # Track last clicked district to detect double-clicks
  last_click <- reactiveVal(NULL)

  # Handle map click
  observeEvent(input$map_shape_click, {
    click <- input$map_shape_click

    if (!is.null(click) && !is.null(click$id)) {
      current <- isolate(selected_district())
      previous <- isolate(last_click())

      # If clicking the same district as currently selected, deselect it
      if (!is.null(current) && current == click$id && previous == click$id) {
        selected_district(NULL)
        updateSelectInput(session, "district_filter", selected = "all")
        last_click(NULL)
      } else {
        # Select the new district
        selected_district(click$id)
        updateSelectInput(session, "district_filter", selected = click$id)
        last_click(click$id)
      }
    }
  })

  # Clear filter button
  observeEvent(input$clear_filter, {
    selected_district(NULL)
    last_click(NULL)
    updateSelectInput(session, "district_filter", selected = "all")
    updateSelectInput(session, "board_filter", selected = "all")
    updateDateRangeInput(session, "date_filter",
                        start = min(hearings_clean$Date, na.rm = TRUE),
                        end = max(hearings_clean$Date, na.rm = TRUE))
  })

  # Sync dropdown selection with map
  observeEvent(input$district_filter, {
    if (input$district_filter == "all") {
      selected_district(NULL)
    } else {
      selected_district(input$district_filter)
    }
  })

  # Display selected district
  output$selected_district <- renderText({
    if (is.null(selected_district())) {
      "All districts"
    } else {
      paste("District", selected_district())
    }
  })

  # Filter hearings data based on selections
  filtered_hearings <- reactive({
    data <- hearings_clean

    # Filter by district
    if (!is.null(selected_district()) && selected_district() != "all") {
      data <- data %>% filter(District == selected_district())
    } else if (input$district_filter != "all") {
      data <- data %>% filter(District == input$district_filter)
    }

    # Filter by board
    if (input$board_filter != "all") {
      data <- data %>% filter(Board == input$board_filter)
    }

    # Filter by date range
    if (!is.null(input$date_filter)) {
      data <- data %>% filter(Date >= input$date_filter[1] & Date <= input$date_filter[2])
    }

    data
  })

  # Update map to highlight selected district
  observe({
    if (!is.null(selected_district())) {
      # Create a data frame for the selected district
      selected_sf <- districts_wgs84 %>% filter(District == selected_district())

      leafletProxy("map") %>%
        clearGroup("selected") %>%
        addPolygons(
          data = selected_sf,
          fillColor = "#e74c3c",
          fillOpacity = 0.4,
          color = "#e74c3c",
          weight = 3,
          group = "selected"
        )
    } else {
      leafletProxy("map") %>%
        clearGroup("selected")
    }
  })

  # Render the data table
  output$hearings_table <- renderDT({
    datatable(
      filtered_hearings(),
      filter = 'top',
      extensions = 'Buttons',
      escape = FALSE,
      options = list(
        pageLength = 25,
        lengthMenu = c(10, 25, 50, 100),
        dom = 'Bfrtip',
        buttons = list(
          list(extend = 'copy', text = 'Copy', className = 'btn-sm'),
          list(extend = 'csv', text = 'CSV', className = 'btn-sm'),
          list(extend = 'excel', text = 'Excel', className = 'btn-sm')
        ),
        scrollX = TRUE,
        scrollY = FALSE,
        scrollCollapse = FALSE,
        paging = TRUE,
        autoWidth = FALSE,
        columnDefs = list(
          list(width = '90px', targets = 0),
          list(width = '60px', targets = 1),
          list(width = '120px', targets = 2),
          list(width = '300px', targets = 3),
          list(width = '180px', targets = 4),
          list(width = '80px', targets = 5)
        ),
        initComplete = JS(
          "function(settings, json) {",
          "$(this.api().table().container()).find('.dt-buttons').css({",
          "'margin-bottom': '0.5rem',",
          "'float': 'right'",
          "});",
          "$(this.api().table().container()).find('.dt-button').css({",
          "'padding': '0.25rem 0.5rem',",
          "'font-size': '0.75rem',",
          "'margin-left': '0.25rem',",
          "'background': '#6c757d',",
          "'border': 'none',",
          "'color': 'white',",
          "'border-radius': '3px'",
          "});",
          "$(this.api().table().container()).css('overflow', 'visible');",
          "}"
        )
      ),
      rownames = FALSE,
      colnames = c('Date', 'District', 'Board', 'Description', 'Address', 'Link'),
      class = 'cell-border stripe hover compact'
    ) %>%
      formatDate(1, 'toDateString') %>%
      formatStyle(
        columns = c(1, 2, 3, 4, 5, 6),
        fontSize = '0.85rem'
      )
  })
}

# Run the application
shinyApp(ui = ui, server = server)
