This project aims to turn PDF agendas from the Framingham Planning Board and License Commissioners into structured data, including geocoding the location of items being discussed and adding District to that info.

It uses several technologies I am keenly interested in when working with local government meeting data:

* Tracking updates to public data sets, in this case via an RSS feed
* Converting PDF to text
* Extracting structured data from text using an LLM
* Geocoding data and assigning it to a polygon area (in this case a city District)
* Displaying data interactively in both a map and searchable table
* Still to hook up: Sending out an email when data I want is updated.

The only thing it's missing is a chatbot! 😅 I don't think this data set needs one, but if you're interested in that, check out my InfoWorld article [How to create your own RAG applications in R](https://www.infoworld.com/article/4020484/generative-ai-rag-comes-to-the-r-tidyverse.html).

Important: I haven't thoroughly tested this yet.

Here is an explanation of the code in this repo, written by Claude and edited by me:

## agendas_to_geocode.R

This script handles the entire data pipeline: fetching RSS feeds, downloading PDFs, extracting text, using an LLM to parse hearing items, and geocoding addresses to city council districts.

### Fetching and parsing the RSS feed

```r
agenda_feed_results <- tidyRSS::tidyfeed(agenda_feed)
```

The `tidyRSS` package makes it easy to pull RSS feeds directly into a data frame. The Granicus platform (used by many local governments) publishes meeting agendas as RSS, so each item contains the meeting title, date, and link to the PDF.

The subsequent `mutate()` block uses regex to extract structured fields from the RSS data. For example, meeting titles come in as "Board of License Commissioners - Dec 08, 2025", so we parse out the board name and date separately. The `ID` field is extracted from the URL's query parameters (`event_id` or `clip_id`) to create unique identifiers for each agenda.

### Incremental processing

```r
existing_ids <- dir("data")
needed_files <- results |>
  filter(!ID %in% existing_ids)
```

Rather than re-downloading everything each run, the script checks which PDFs already exist in the `data/` folder. Only new agendas get processed. There's also cleanup logic that deletes PDFs older than 30 days to avoid accumulating files indefinitely.

### PDF text extraction with error handling

```r
pdf_text_safely <- purrr::possibly(pdftools::pdf_text, otherwise = "")
```

I'm using the pdftools R package to turn the PDFs into text. If the format was more challenging or 100% accuracy was critical, I'd probably use a cloud service like Llamacloud's LlamaParse API (paid service but generous free tire). I wrote an R wrapper for that API, which is in my [rAIutils package](https://github.com/smach/rAIutils).

The `purrr::possibly()` wrapper handles error checking for batch processing. If a PDF is corrupted or fails to parse, instead of crashing the whole script, it returns an empty string and continues. The extracted text from all pages gets collapsed into a single string per agenda.

### Structured data extraction with ellmer

This is where LLMs come in. The `ellmer` package provides an easy-to-use interface for using LLMs to extrac structured data from plain text.

```r
type_hearing_item <- type_object(
  description = type_string("Short description of the hearing item"),
  address = type_string("Address where the hearing will take place", required = FALSE)
)

type_hearings <- type_array(type_hearing_item)
```

First, we define the scheme we want for the structured data, using `type_object()` (structure of a single item) and `type_array()` (lets the LLM know we will likely have more than one object in the text, so return a data frame not a single item). The `required = FALSE` on address handles items that don't have a physical location.

```r
chat <- chat_openai(model = "gpt-4.1", system_prompt = "...")

chat$chat_structured(
  paste("Extract all hearing items from the following agenda text:", Text),
  type = type_hearings
)
```

The `chat_structured()` method sends the text to the LLM and instructs the model to return a response that matches our schema. No regex parsing of LLM output needed—you get back a proper R list that can be directly unnested into a data frame. This is more reliable than asking an LLM for JSON and hoping it's valid.

An OpenAI API key is required for this part. You can choose another provider as well, ellmer handles a number of others including Google Gemini and Anthropic. While it does allow for local models using ollama, too, frontier providers' LLMs are currently significantly more reliable for tool calling.

### Geocoding with tidygeocoder

```r
hearings_geocoded <- hearings_df %>%
  geocode(
    address = address_full,
    method = "geocodio"
  )
```

The `tidygeocoder` package provides a consistent interface to multiple geocoding services. Here I chose the Geocodio service, which was more reliable than free options I tested. While paid, it has a generous free tier and I don't come close to using 10,000 calls per day! It does requires an API key to be set via `GEOCODIO_API_KEY` environment variable). The `geocode()` function adds latitude and longitude columns to the data frame.

### Spatial joins with sf

```r
hearings_with_districts <- hearings_geocoded %>%
  sf::st_as_sf(coords = c("longitude", "latitude"), crs = 4326) %>%
  sf::st_join(framingham_gis, join = sf::st_within) %>%
  sf::st_drop_geometry()
```

This is a common pattern for point-in-polygon operations. We convert the geocoded data to an `sf` spatial object, then use `st_join()` with `st_within` to find which district polygon contains each point. The `st_drop_geometry()` at the end converts back to a regular data frame, keeping the District column we just matched.

## app.R

The Shiny app displays the processed hearing data with an interactive map and filterable table.

### UI structure with bslib

```r
ui <- page_navbar(
  theme = bs_theme(version = 5, ...),
  nav_panel("Dashboard", ...)
)
```

The app uses `bslib` for modern Bootstrap 5 styling (one thing I've learned from R Shiny experts is that you should always use bslib in your new Shiny apps. The only reason its functionality hasn't been folded into core R Shiny is for backwards compatibility with older apps.). `page_navbar()` creates the overall layout, and `bs_theme()` customizes colors and fonts (including Google Fonts via `font_google()`). The layout uses `card()` components for the map and filters, with flexbox CSS for responsive side-by-side arrangement.

### Reactive state management

```r
selected_district <- reactiveVal(NULL)
last_click <- reactiveVal(NULL)
```

`reactiveVal()` creates mutable reactive values, which are like variables that automatically trigger updates when they change. `selected_district` tracks which district is currently filtered, while `last_click` enables toggle behavior (click once to select, click again to deselect).

### Leaflet map with choropleth

```r
pal <- colorNumeric(
  palette = c("#e8f4f8", "#a8d5e2", "#2980b9"),
  domain = districts_wgs84$hearing_count
)
```

The `colorNumeric()` function creates a color scale that maps hearing counts to colors. This palette goes from light blue (few hearings) to dark blue (many hearings).

```r
addPolygons(
  fillColor = ~pal(hearing_count),
  layerId = ~District,
  highlightOptions = highlightOptions(...)
)
```

`addPolygons()` draws the district boundaries. The `layerId` parameter is crucial—it lets us identify which district was clicked. `highlightOptions` provides hover feedback.

[Note: The new mapgl R package is now among my favorites for mapping in R, but I don't know how it plays with bi-directional Ahiny filtering. Claude chose leaflet, which I'm sure it has much more training data on.]

### Bidirectional filter sync

This is where I definitely needed Claude to write the code, as I didn't know how to write code so that clicking the map filters the table, and choosing Shiny filters below the map affects the map.

Claude explains:

The app keeps the map selection and dropdown filter in sync:

```r
observeEvent(input$map_shape_click, {
  # When map is clicked, update the dropdown
  updateSelectInput(session, "district_filter", selected = click$id)
})

observeEvent(input$district_filter, {
  # When dropdown changes, update the map highlight
  selected_district(input$district_filter)
})
```

This bidirectional binding means users can filter either way and both controls stay synchronized.

### Dynamic map updates with leafletProxy

```r
leafletProxy("map") %>%
  clearGroup("selected") %>%
  addPolygons(data = selected_sf, group = "selected", ...)
```

`leafletProxy()` modifies an existing map without re-rendering the whole thing. This is essential for performance—we just add/remove a highlight layer rather than rebuilding the entire map on each click.

### DT table with export buttons

```r
datatable(
  filtered_hearings(),
  extensions = 'Buttons',
  options = list(
    dom = 'Bfrtip',
    buttons = list(
      list(extend = 'csv', ...),
      list(extend = 'excel', ...)
    )
  )
)
```

The `DT` package wraps DataTables.js. The `extensions = 'Buttons'` adds export functionality, and `dom = 'Bfrtip'` controls the layout (Buttons, filter, processing, table, info, pagination). The `escape = FALSE` parameter allows our HTML links in the Link column to render as clickable anchors.

