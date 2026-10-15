# ============================================================
# MASTER SCRIPT 4 of 4: Graphs + Excel summary report
#
# Works for any participant who follows the folder/file convention
# described in the repository README (same layout as S15).
#
# >>> THE ONLY LINE YOU SHOULD NEED TO CHANGE (for interactive/RStudio use): <<<
PARTICIPANT_ID <- "S15"
# >>> ------------------------------------------ <<<
#
# When run from the command line (e.g. Rscript in a terminal), this
# value is overridden by a command-line argument instead:
#   Rscript master_04_graphs_and_summary.R <PARTICIPANT_ID>
.args <- commandArgs(trailingOnly = TRUE)
if (length(.args) >= 1 && nzchar(.args[1])) PARTICIPANT_ID <- .args[1]
#
# Reads master_03's output and produces:
#   1. Six PNG graphs:
#        01 - ENMO by shift type (box plot)
#        02 - PA category breakdown (%) by shift type
#        03 - Day vs Night comparison (ENMO / % / minutes)
#        04 - Postcall (day after Night/24h shift) vs Off comparison
#        05 - Daily timeline of mean ENMO, coloured by dominant shift type
#        06 - Mean minutes per shift in each PA category, by shift type
#   2. {ID}_final_1min_report.csv -- the 7-column report:
#        Participant ID, Date/Time (South Africa), ENMO_mg, Category of PA,
#        Sleep/Nap/Wake, Shift type, Hospital
#   3. {ID}_summary_report.xlsx -- ReadMe, Min_by_Min_Data, Basic_Stats,
#        PA_by_ShiftType, PA_Minutes_MeanSD_by_ShiftType,
#        PA_Minutes_per_Shift_raw, Day_vs_Night, Postcall_vs_Off,
#        Daily_Summary
#
# NOTE on "Postcall": this label is used as "day after a night/24h shift".
# For S15 this was confirmed against the shift log (every Postcall row
# directly follows a Night or 24-Hour row) -- worth re-checking that
# still holds for each new participant's shift log before trusting the
# Postcall_vs_Off comparison.
# ============================================================

required_packages <- c("tidyverse", "lubridate", "openxlsx", "patchwork")
missing_packages <- required_packages[!required_packages %in% rownames(installed.packages())]
if (length(missing_packages) > 0) install.packages(missing_packages)

library(tidyverse)
library(lubridate)
library(openxlsx)

# Root folder holding one sub-folder per participant (see README).
# Set the FINAL_ER_ROOT environment variable, or edit the fallback path.
final_er_root <- Sys.getenv("FINAL_ER_ROOT", unset = "path/to/FINAL_ER")
tz_sast       <- "Africa/Johannesburg"

project_dir <- file.path(final_er_root, PARTICIPANT_ID)
input_file  <- file.path(project_dir, "output", paste0(PARTICIPANT_ID, "_clean_1min_with_shift.csv"))
graphs_dir  <- file.path(project_dir, "output", "graphs")
csv_file    <- file.path(project_dir, "output", paste0(PARTICIPANT_ID, "_final_1min_report.csv"))
excel_file  <- file.path(project_dir, "output", paste0(PARTICIPANT_ID, "_summary_report.xlsx"))

if (!file.exists(input_file)) {
  stop("[", PARTICIPANT_ID, "] master_03 output not found: ", input_file, " -- run master_03_attach_shift.R first.")
}
dir.create(graphs_dir, recursive = TRUE, showWarnings = FALSE)

shift_order <- c("Day", "Night", "24-Hour", "Postcall", "Off")
pa_cats     <- c("Sedentary", "Light", "Moderate", "Vigorous")

shift_colors <- c(
  "Day" = "#4C72B0", "Night" = "#264160", "24-Hour" = "#8172B2",
  "Postcall" = "#DD8452", "Off" = "#55A868"
)
cat_colors <- c(
  "Sedentary" = "#B0B0B0", "Light" = "#8ECFC9",
  "Moderate" = "#FFBE7A", "Vigorous" = "#FA7F6F"
)

data <- read_csv(input_file, show_col_types = FALSE) %>%
  mutate(
    date = as.Date(date),
    shift_type = factor(shift_type, levels = shift_order)
  )

has_hospital_col <- "hospital_site" %in% names(data)

included <- data %>% filter(include_in_PA_analysis == TRUE)


# ------------------------------------------------------------
# Graph 1: ENMO box plot by shift type
# ------------------------------------------------------------

g1 <- ggplot(included, aes(x = shift_type, y = ENMO_mg, fill = shift_type)) +
  geom_boxplot(outlier.shape = NA) +
  coord_cartesian(ylim = c(0, quantile(included$ENMO_mg, 0.98, na.rm = TRUE))) +
  scale_fill_manual(values = shift_colors, guide = "none") +
  labs(
    title = paste0(PARTICIPANT_ID, ": PA Intensity (ENMO) by Shift Type"),
    subtitle = "Waking, valid minutes only; y-axis capped at 98th percentile for readability",
    x = "Shift type", y = "ENMO (mg)"
  ) +
  theme_minimal(base_size = 12)

ggsave(file.path(graphs_dir, "01_ENMO_boxplot_by_shift_type.png"), g1, width = 7, height = 5, dpi = 150)


# ------------------------------------------------------------
# Graph 2: PA category breakdown (%) by shift type
# ------------------------------------------------------------

pct_by_shift <- included %>%
  count(shift_type, activity_intensity) %>%
  group_by(shift_type) %>%
  mutate(pct = 100 * n / sum(n)) %>%
  ungroup() %>%
  mutate(activity_intensity = factor(activity_intensity, levels = pa_cats))

g2 <- ggplot(pct_by_shift, aes(x = shift_type, y = pct, fill = activity_intensity)) +
  geom_col() +
  scale_fill_manual(values = cat_colors, name = "Category of PA") +
  labs(
    title = paste0(PARTICIPANT_ID, ": PA Category Breakdown by Shift Type"),
    x = "Shift type", y = "% of included minutes"
  ) +
  theme_minimal(base_size = 12)

ggsave(file.path(graphs_dir, "02_PA_category_by_shift_type.png"), g2, width = 7.5, height = 5, dpi = 150)


# ------------------------------------------------------------
# Per-shift-OCCURRENCE minute counts (each individual shift, identified by
# shift_id, is one occurrence). Basis for the mean (SD) minutes table/graphs.
# ------------------------------------------------------------

per_shift <- included %>%
  filter(!is.na(shift_id)) %>%
  group_by(shift_id, shift_type) %>%
  summarise(
    Sedentary = sum(activity_intensity == "Sedentary", na.rm = TRUE),
    Light     = sum(activity_intensity == "Light", na.rm = TRUE),
    Moderate  = sum(activity_intensity == "Moderate", na.rm = TRUE),
    Vigorous  = sum(activity_intensity == "Vigorous", na.rm = TRUE),
    MVPA      = sum(MVPA, na.rm = TRUE),
    Total_included_minutes = n(),
    .groups = "drop"
  ) %>%
  mutate(shift_type = factor(shift_type, levels = shift_order)) %>%
  arrange(shift_type, shift_id)

minutes_summary <- per_shift %>%
  select(shift_id, shift_type, all_of(pa_cats)) %>%
  pivot_longer(cols = all_of(pa_cats), names_to = "category", values_to = "minutes") %>%
  mutate(category = factor(category, levels = pa_cats)) %>%
  group_by(shift_type, category, .drop = FALSE) %>%
  summarise(
    mean_minutes = mean(minutes, na.rm = TRUE),
    sd_minutes   = if (n() > 1) sd(minutes, na.rm = TRUE) else 0,
    n_shifts     = n(),
    .groups = "drop"
  )


# ------------------------------------------------------------
# Graph 3: Day vs Night
# ------------------------------------------------------------

g3a <- included %>%
  filter(shift_type %in% c("Day", "Night")) %>%
  mutate(shift_type = droplevels(shift_type)) %>%
  ggplot(aes(x = shift_type, y = ENMO_mg, fill = shift_type)) +
  geom_boxplot(outlier.shape = NA) +
  coord_cartesian(ylim = c(0, quantile(included$ENMO_mg, 0.98, na.rm = TRUE))) +
  scale_fill_manual(values = shift_colors, guide = "none") +
  labs(title = "ENMO distribution", x = NULL, y = "ENMO (mg)") +
  theme_minimal(base_size = 11)

g3b <- pct_by_shift %>%
  filter(shift_type %in% c("Day", "Night")) %>%
  ggplot(aes(x = shift_type, y = pct, fill = activity_intensity)) +
  geom_col() +
  scale_fill_manual(values = cat_colors, name = "Category") +
  labs(title = "PA category breakdown (%)", x = NULL, y = "% of included minutes") +
  theme_minimal(base_size = 11)

g3c <- minutes_summary %>%
  filter(shift_type %in% c("Day", "Night")) %>%
  ggplot(aes(x = shift_type, y = mean_minutes, fill = category)) +
  geom_col(position = position_dodge(width = 0.8), width = 0.7) +
  geom_errorbar(
    aes(ymin = pmax(0, mean_minutes - sd_minutes), ymax = mean_minutes + sd_minutes),
    position = position_dodge(width = 0.8), width = 0.25
  ) +
  scale_fill_manual(values = cat_colors, name = "Category") +
  labs(title = "Minutes by category", x = NULL, y = "Minutes per shift (mean ± SD)") +
  theme_minimal(base_size = 11)

g3 <- patchwork::wrap_plots(g3a, g3b, g3c, nrow = 1) +
  patchwork::plot_annotation(title = paste0(PARTICIPANT_ID, ": Day Shift vs Night Shift - Physical Activity Comparison"))

ggsave(file.path(graphs_dir, "03_Day_vs_Night.png"), g3, width = 13, height = 4.5, dpi = 150)


# ------------------------------------------------------------
# Graph 4: Postcall (day after Night/24-Hour shift) vs Off
# ------------------------------------------------------------

g4a <- included %>%
  filter(shift_type %in% c("Postcall", "Off")) %>%
  mutate(shift_type = droplevels(shift_type)) %>%
  ggplot(aes(x = shift_type, y = ENMO_mg, fill = shift_type)) +
  geom_boxplot(outlier.shape = NA) +
  coord_cartesian(ylim = c(0, quantile(included$ENMO_mg, 0.98, na.rm = TRUE))) +
  scale_fill_manual(values = shift_colors, guide = "none") +
  scale_x_discrete(labels = c("Postcall" = "Postcall\n(day after night/24h)", "Off" = "Off")) +
  labs(title = "ENMO distribution", x = NULL, y = "ENMO (mg)") +
  theme_minimal(base_size = 11)

g4b <- pct_by_shift %>%
  filter(shift_type %in% c("Postcall", "Off")) %>%
  ggplot(aes(x = shift_type, y = pct, fill = activity_intensity)) +
  geom_col() +
  scale_fill_manual(values = cat_colors, name = "Category") +
  scale_x_discrete(labels = c("Postcall" = "Postcall\n(day after night/24h)", "Off" = "Off")) +
  labs(title = "PA category breakdown (%)", x = NULL, y = "% of included minutes") +
  theme_minimal(base_size = 11)

g4c <- minutes_summary %>%
  filter(shift_type %in% c("Postcall", "Off")) %>%
  ggplot(aes(x = shift_type, y = mean_minutes, fill = category)) +
  geom_col(position = position_dodge(width = 0.8), width = 0.7) +
  geom_errorbar(
    aes(ymin = pmax(0, mean_minutes - sd_minutes), ymax = mean_minutes + sd_minutes),
    position = position_dodge(width = 0.8), width = 0.25
  ) +
  scale_fill_manual(values = cat_colors, name = "Category") +
  scale_x_discrete(labels = c("Postcall" = "Postcall\n(day after night/24h)", "Off" = "Off")) +
  labs(title = "Minutes by category", x = NULL, y = "Minutes per shift (mean ± SD)") +
  theme_minimal(base_size = 11)

g4 <- patchwork::wrap_plots(g4a, g4b, g4c, nrow = 1) +
  patchwork::plot_annotation(title = paste0(PARTICIPANT_ID, ": Day After Night/24h Shift (Postcall) vs Off Day"))

ggsave(file.path(graphs_dir, "04_Postcall_vs_Off.png"), g4, width = 13, height = 4.5, dpi = 150)


# ------------------------------------------------------------
# Graph 5: Daily timeline of mean ENMO, coloured by dominant shift type
# ------------------------------------------------------------

daily <- data %>%
  group_by(date) %>%
  summarise(
    valid_minutes = sum(valid_minute, na.rm = TRUE),
    sleep_minutes = sum(main_sleep, na.rm = TRUE),
    nap_minutes   = sum(nap, na.rm = TRUE),
    wake_minutes  = sum(waking, na.rm = TRUE),
    included_PA_minutes = sum(include_in_PA_analysis, na.rm = TRUE),
    MVPA_minutes  = sum(MVPA, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  left_join(
    included %>% group_by(date) %>% summarise(mean_ENMO_mg = round(mean(ENMO_mg, na.rm = TRUE), 2), .groups = "drop"),
    by = "date"
  ) %>%
  left_join(
    data %>% filter(!is.na(shift_type)) %>% count(date, shift_type) %>%
      group_by(date) %>% slice_max(n, n = 1, with_ties = FALSE) %>%
      select(date, dominant_shift_type = shift_type),
    by = "date"
  )

g5 <- ggplot(daily, aes(x = date, y = mean_ENMO_mg, fill = dominant_shift_type)) +
  geom_col() +
  scale_fill_manual(values = shift_colors, name = "Shift type", na.value = "grey80") +
  labs(
    title = paste0(PARTICIPANT_ID, ": Daily Mean PA Intensity Across the Study Period"),
    subtitle = "Bar colour = dominant shift type that day",
    x = NULL, y = "Mean ENMO (mg), included minutes"
  ) +
  theme_minimal(base_size = 11) +
  theme(axis.text.x = element_text(angle = 90, vjust = 0.5, hjust = 1))

ggsave(file.path(graphs_dir, "05_daily_timeline.png"), g5, width = 11, height = 4.5, dpi = 150)


# ------------------------------------------------------------
# Graph 6: mean minutes per shift in each PA category, by shift type
# ------------------------------------------------------------

g6 <- ggplot(minutes_summary, aes(x = shift_type, y = mean_minutes, fill = category)) +
  geom_col(position = position_dodge(width = 0.8), width = 0.7) +
  geom_errorbar(
    aes(ymin = pmax(0, mean_minutes - sd_minutes), ymax = mean_minutes + sd_minutes),
    position = position_dodge(width = 0.8), width = 0.25
  ) +
  scale_fill_manual(values = cat_colors, name = "Category of PA") +
  labs(
    title = paste0(PARTICIPANT_ID, ": Mean Minutes per Shift in Each PA Category, by Shift Type"),
    subtitle = "Error bars = SD across shift occurrences",
    x = "Shift type", y = "Minutes per shift (mean ± SD)"
  ) +
  theme_minimal(base_size = 12)

ggsave(file.path(graphs_dir, "06_mean_minutes_by_category_and_shift_type.png"), g6, width = 9, height = 5.5, dpi = 150)

message("[", PARTICIPANT_ID, "] Saved 6 graphs to: ", graphs_dir)


# ------------------------------------------------------------
# Build the summary tables
# ------------------------------------------------------------

pa_table <- function(levels_wanted) {
  included %>%
    filter(shift_type %in% levels_wanted) %>%
    mutate(shift_type = factor(shift_type, levels = levels_wanted)) %>%
    group_by(shift_type, .drop = FALSE) %>%
    summarise(
      `Included minutes` = n(),
      `Mean ENMO (mg)`   = round(mean(ENMO_mg, na.rm = TRUE), 2),
      `Median ENMO (mg)` = round(median(ENMO_mg, na.rm = TRUE), 2),
      `MVPA %`           = round(100 * mean(MVPA, na.rm = TRUE), 1),
      `% Sedentary`      = round(100 * mean(activity_intensity == "Sedentary", na.rm = TRUE), 1),
      `% Light`          = round(100 * mean(activity_intensity == "Light", na.rm = TRUE), 1),
      `% Moderate`       = round(100 * mean(activity_intensity == "Moderate", na.rm = TRUE), 1),
      `% Vigorous`       = round(100 * mean(activity_intensity == "Vigorous", na.rm = TRUE), 1),
      .groups = "drop"
    ) %>%
    rename(`Shift type` = shift_type)
}

pa_by_shift_tbl  <- pa_table(shift_order)
day_night_tbl    <- pa_table(c("Day", "Night"))
postcall_off_tbl <- pa_table(c("Postcall", "Off"))

metric_cols <- c("Sedentary", "Light", "Moderate", "Vigorous", "MVPA", "Total_included_minutes")

mean_sd_minutes_tbl <- map_dfr(shift_order, function(st) {
  sub <- per_shift %>% filter(shift_type == st)
  n <- nrow(sub)
  cell_values <- map(metric_cols, function(m) {
    mean_v <- if (n > 0) mean(sub[[m]], na.rm = TRUE) else NA
    sd_v   <- if (n > 1) sd(sub[[m]], na.rm = TRUE) else 0
    if (n > 0) sprintf("%.1f (%.1f)", mean_v, sd_v) else "-"
  })
  names(cell_values) <- ifelse(
    metric_cols == "Total_included_minutes",
    "Total included minutes: mean (SD)",
    paste0(metric_cols, " minutes: mean (SD)")
  )
  as_tibble(c(list(`Shift type` = st, `n shifts` = n), cell_values))
})

basic_stats <- tibble(
  Metric = c(
    "Participant", "Total one-minute rows", "Date range start", "Date range end",
    "Number of calendar days", "Valid minutes (device worn)", "Sleep minutes", "Nap minutes",
    "Wake minutes", "Minutes included in PA analysis (valid + waking)", "MVPA minutes",
    "Mean ENMO, included minutes (mg)", "Median ENMO, included minutes (mg)",
    "Minutes with no shift type assigned", "ENMO thresholds used (mg)"
  ),
  Value = c(
    PARTICIPANT_ID, nrow(data), as.character(min(data$date)), as.character(max(data$date)),
    n_distinct(data$date), sum(data$valid_minute, na.rm = TRUE), sum(data$main_sleep, na.rm = TRUE),
    sum(data$nap, na.rm = TRUE), sum(data$waking, na.rm = TRUE),
    sum(data$include_in_PA_analysis, na.rm = TRUE), sum(data$MVPA, na.rm = TRUE),
    round(mean(included$ENMO_mg, na.rm = TRUE), 2), round(median(included$ENMO_mg, na.rm = TRUE), 2),
    sum(is.na(data$shift_type)), "Sedentary <36, Light 36-<92, Moderate 92-<283, Vigorous >=283"
  )
)

final_report <- data %>%
  transmute(
    `Participant ID`           = participant_id,
    `Date/Time (South Africa)` = datetime_SAST,
    ENMO_mg                    = ENMO_mg,
    `Category of PA`           = activity_intensity,
    `Sleep/Nap/Wake`           = sleep_nap_wake,
    `Shift type`               = as.character(shift_type),
    Hospital                   = if (has_hospital_col) hospital_site else NA_character_
  )

write_csv(final_report, csv_file, na = "")
message("[", PARTICIPANT_ID, "] Created: ", csv_file)

readme_lines <- c(
  paste0(PARTICIPANT_ID, " - GGIR Physical Activity / Sleep / Shift Report"),
  paste0("Participant: ", PARTICIPANT_ID),
  "Source: raw GENEActiv .bin -> GGIR (Parts 1-5) -> manual sleep/nap flagging -> shift-diary join",
  "",
  "Sheet guide:",
  "  Min_by_Min_Data                 - one row per minute of recording (the core dataset)",
  "  Basic_Stats                     - headline totals for the whole recording",
  "  PA_by_ShiftType                 - % time breakdown and ENMO by shift type (all minutes pooled)",
  "  PA_Minutes_MeanSD_by_ShiftType  - mean (SD) MINUTES per shift occurrence, by PA category and shift type",
  "  PA_Minutes_per_Shift_raw        - the underlying per-shift-instance minute counts behind that table",
  "  Day_vs_Night                    - focused % comparison: Day shift vs Night shift",
  "  Postcall_vs_Off                 - focused % comparison: day after a night/24h shift vs a genuine Off day",
  "  Daily_Summary                   - one row per calendar day",
  "",
  "Column notes (Min_by_Min_Data):",
  "  Category of PA - Sedentary/Light/Moderate/Vigorous. Blank during Sleep, Nap, or invalid minutes.",
  "  Sleep/Nap/Wake  - from the manual Philips-derived sleep/nap log, not GGIR's automatic detection.",
  "  Shift type       - from the shift diary. Blank where no shift row covers that minute (no guessing).",
  paste0("  Hospital          - ", if (has_hospital_col) "from the shift log's hospital_site column." else "not yet available; left blank for now."),
  "",
  "About PA_Minutes_MeanSD_by_ShiftType:",
  "  Each shift in the diary is treated as one occurrence. For every occurrence, minutes in each PA",
  "  category are counted, then the mean and SD are taken ACROSS occurrences of that shift type. This",
  "  is more informative than pooling all minutes together, because it shows how much PA varies from",
  "  one shift of that type to the next, not just the average over the whole study.",
  "",
  "ENMO thresholds (mg): Sedentary <36 | Light 36-<92 | Moderate 92-<283 | Vigorous >=283",
  "",
  "'Postcall' is used here as 'day after a night or 24-hour shift'. This was confirmed against S15's",
  "shift log (every Postcall row directly follows a Night or 24-Hour row) -- re-check this assumption",
  "holds for each new participant before relying on the Postcall_vs_Off comparison."
)


# ------------------------------------------------------------
# Write the Excel workbook
# ------------------------------------------------------------

wb <- createWorkbook()

addWorksheet(wb, "ReadMe")
writeData(wb, "ReadMe", tibble(x = readme_lines), colNames = FALSE)
setColWidths(wb, "ReadMe", cols = 1, widths = 100)

header_style <- createStyle(fgFill = "#4C72B0", fontColour = "white", textDecoration = "bold")

add_table_sheet <- function(sheet_name, tbl) {
  addWorksheet(wb, sheet_name)
  writeData(wb, sheet_name, tbl, headerStyle = header_style)
  freezePane(wb, sheet_name, firstRow = TRUE)
  setColWidths(wb, sheet_name, cols = 1:ncol(tbl), widths = "auto")
}

add_table_sheet("Min_by_Min_Data", final_report)
add_table_sheet("Basic_Stats", basic_stats)
add_table_sheet("PA_by_ShiftType", pa_by_shift_tbl)
add_table_sheet("PA_Minutes_MeanSD_by_ShiftType", mean_sd_minutes_tbl)
add_table_sheet("PA_Minutes_per_Shift_raw", per_shift)
add_table_sheet("Day_vs_Night", day_night_tbl)
add_table_sheet("Postcall_vs_Off", postcall_off_tbl)
add_table_sheet("Daily_Summary", daily)

saveWorkbook(wb, excel_file, overwrite = TRUE)
message("[", PARTICIPANT_ID, "] Created: ", excel_file)

message("[", PARTICIPANT_ID, "] All done.")
