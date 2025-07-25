###########################################################
# bulkCAT - multispecies rarity assessments using precompiled taxa occurrence datasets and NatureServe methodology
# read the "readme.txt" file for more information
# Created in October 2024 by Clark Hollenberg at the Colorado Natural Heritage Program
# Contact: chollenb@colostate.edu
############################################################

# Load libraries - note you may need to install these first before running the script
library(readr)
library(dplyr)
library(sf)
library(stringr)
library(dbscan)

# ===== User Inputs =====
# Replace with your pre-curated multispecies dataset (must contain SNAME, decimalLatitude, decimalLongitude columns)
input_csv <- "species_occurrence_data.csv" 

output_xlsx <- "bulkCAT_output.xlsx"   # user-designated output filepath
equal_area_crs <- 6933  # World Cylindrical Equal Area projection
grid_size <- 2000       # 2 km x 2 km grid
eo_separation <- 1000   # 1 km standard for Element Occurrence clusters

# ===== Load and prepare points =====
df <- read_csv(input_csv, show_col_types = FALSE) %>%
  filter(!is.na(decimalLatitude), !is.na(decimalLongitude), !is.na(SNAME))

# Create sf object from lat/lon in WGS84
gdf <- st_as_sf(df, coords = c("decimalLongitude", "decimalLatitude"), crs = 4326)

# Project to equal-area CRS
gdf_proj <- st_transform(gdf, crs = equal_area_crs)

# Identify species list
species_list <- sort(unique(gdf_proj$SNAME))

results <- list()

# ===== Species loop =====
for (species in species_list) {
  cat("Processing:", species, "\n")
  
  # Match all derived varieties/subspecies if just genus + species
  if (length(str_split(species, "\\s+")[[1]]) == 2) {  # if a binomial is selected, include trinomial variations
    subset <- gdf_proj %>% filter(str_starts(SNAME, species))
    subset_buffer <- gdf %>% filter(str_starts(SNAME, species))
  } else { # if a trinomial is selected, only rank the trinomial occurrences.
    subset <- gdf_proj %>% filter(SNAME == species)
    subset_buffer <- gdf %>% filter(SNAME == species)
  }
  
  num_occur <- nrow(subset)
  if (num_occur == 0) next
  
  ###### EOO: Convex Hull Area ######
  hull <- st_convex_hull(st_union(subset))
  eoo_area_km2 <- as.numeric(st_area(hull)) / 1e6
  
  ###### AOO: 2x2 km Grid ######
    
  # simple coordinate division calculation method
  coords <- st_coordinates(subset)
  bottomleftpoints <- floor(coords/grid_size)
  uniquecells <- unique(bottomleftpoints)
  aoo_cells <- nrow(uniquecells)
  
  

  ###### EO Cluster Count (1 km buffer) ######
  
  # Run DBSCAN with 1000m (1 km) epsilon and minPts = 1
  # This groups all points within 1 km of each other
  clustering <- dbscan(coords, eps = eo_separation, minPts = 1)
  
  # Assign cluster IDs back to points
  subset$cluster_id <- clustering$cluster
  
  # Now count number of unique clusters
  num_clusters <- length(unique(subset$cluster_id))
  
  ###### Append to results ######
  results[[length(results) + 1]] <- data.frame(
    species = species,
    num_occurrences = num_occur,
    eoo_area_km2 = round(eoo_area_km2, 2),
    aoo_num_cells = aoo_cells,
    num_EOs = num_clusters
  )
}

final_results <- do.call(rbind, results)

# ----------------------------------------------------------------
#  RANKING ROLL‑UP
# ----------------------------------------------------------------

library(readxl)   # read rules
library(writexl)  # write Excel

rules_df <- data.frame(
  EOOVal = c(100, 250, 1000, 5000, 20000, 200000, 2500000, 25000000, NA),
  EOOScore = c(0, 0.79, 1.57, 2.36, 3.14, 3.93, 4.71, 5.5, NA),
  AOOVal = c(1, 2, 5, 20, 125, 500, 5000, 50000, 10000000),
  AOOScore = c(0, 0.69, 1.38, 2.06, 2.75, 3.44, 4.13, 4.81, 5.5),
  NumVal = c(5, 20, 80, 300, 1200, 1000000, NA, NA, NA),
  NumScore = c(0, 1.38, 2.75, 4.13, 5.5, 5.5, NA, NA, NA),
  RankVal = c(1.5, 2.5, 3.5, 4.5, 6, NA, NA, NA, NA),
  RankScore = c("S1", "S2", "S3", "S4", "S5", NA, NA, NA, NA),
  stringsAsFactors = FALSE
)

assign_points <- function(value, rules, metric) {
  val_col   <- paste0(metric, "Val")
  score_col <- paste0(metric, "Score")
  idx <- which(value <= rules[[val_col]])[1]
  if (is.na(idx)) return(0)
  rules[[score_col]][idx]
}

score_eoo  <- function(x) vapply(x, assign_points, numeric(1), rules = rules_df, metric = "EOO")
score_aoo  <- function(x) vapply(x, assign_points, numeric(1), rules = rules_df, metric = "AOO")
score_num  <- function(x) vapply(x, assign_points, numeric(1), rules = rules_df, metric = "Num")
score_rank <- function(x)
  vapply(x, assign_points, character(1),   # <-- expect one character
         rules = rules_df, metric = "Rank")


final_results <- final_results %>%
  mutate(
    Points = (score_eoo(eoo_area_km2) +
                2 * score_aoo(aoo_num_cells) +
                score_num(num_EOs)) / 4,
    SRank  = score_rank(Points)
  )

write_xlsx(final_results, output_xlsx)
cat("✓ Finished — results written to", output_xlsx, "\n")

