

library(sf)
library(dplyr)

# 1. Read your private shapefile from the data-raw folder
# Replace 'revised_precincts.shp' with your actual filename
raw_shape <- read_sf("gis/framingham_precincts_w_districts.shp")

# 2. Prepare the data
# If your shapefile has precincts (e.g., 18 polygons) but you want 
# to return Districts (9 polygons), you can "dissolve" the boundaries here.
# This assumes your shapefile has a column named 'DISTRICT_ID'
framingham_districts <- raw_shape %>%
  group_by(District) %>%   # Group by the district column
  summarise() %>%             # Dissolve internal precinct lines
  st_transform(4326)          # Convert to WGS84 (Lat/Lon) for the web



# I'm also creating a new sf object in data-raw because I want to have that in case I want it for other reasons.
sf::write_sf(framingham_districts, "gis/framingham_districts.shp") 
