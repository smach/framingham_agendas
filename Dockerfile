FROM rocker/r2u:jammy

# Bypass D-Bus for system installs
RUN echo 'options(bspm.sudo = TRUE)' >> "${R_HOME}/etc/Rprofile.site"

# Install system dependencies and R binary packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    # Geo libraries for sf
    libgdal-dev libgeos-dev libproj-dev libudunits2-dev \
    # For pdftools
    libpoppler-cpp-dev \
    # R packages available as binaries
    r-cran-pdftools r-cran-tidyrss r-cran-glue r-cran-dplyr \
    r-cran-data.table r-cran-tidyr r-cran-stringr r-cran-rio \
    r-cran-nanoparquet r-cran-purrr r-cran-tidygeocoder r-cran-sf \
    r-cran-lubridate r-cran-dt r-cran-leaflet r-cran-htmlwidgets \
    r-cran-shiny r-cran-bslib r-cran-rsconnect r-cran-emayili \
    && rm -rf /var/lib/apt/lists/*

# Install packages not available as system binaries
RUN Rscript -e "install.packages('ellmer')"
