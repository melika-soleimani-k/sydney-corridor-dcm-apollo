############################################################
# Discrete Choice Modeling (DCM): Australian Corridor Study
# Package: apollo | Models: MNL & Mixed Logit
############################################################

# 1. Install required packages (run once)
packages <- c("apollo", "AER", "tidyverse")
installed <- packages %in% rownames(installed.packages())
if (any(!installed)) {
  install.packages(packages[!installed])
}

# 2. Load packages
lapply(packages, library, character.only = TRUE)

# 3. Load Australian intercity mode choice dataset
data("TravelMode", package = "AER")
head(TravelMode, 8)
# 4. Print full first 8 rows (2 travelers x 4 transport modes)
print(TravelMode[1:8, ])

# 5. Reshape data from Long (840 rows) to Wide (210 rows) for apollo
sydney_wide <- TravelMode %>%
  mutate(
    individual = as.numeric(as.character(individual)),
    mode = as.character(mode),
    chosen_mode = ifelse(choice == "yes", mode, NA)
  ) %>%
  group_by(individual) %>%
  mutate(
    choice_id = match(first(na.omit(chosen_mode)), c("air", "train", "bus", "car"))
  ) %>%
  ungroup() %>%
  select(individual, choice_id, income, size, mode, wait, vcost, travel) %>%
  pivot_wider(
    names_from = mode,
    values_from = c(wait, vcost, travel),
    names_sep = "_"
  ) %>%
  as.data.frame()

# 6. Check the reshaped dataset (should be 210 rows and 16 columns)
dim(sydney_wide)
head(sydney_wide, 3)
# 7. Initialize Apollo and set up database
apollo_initialise()

database <- sydney_wide

apollo_control <- list(
  modelName       = "Model1_Baseline_MNL",
  modelDescr      = "Baseline Multinomial Logit Model - Sydney Corridor",
  indivID         = "individual",
  outputDirectory = "output"
)

# 8. Define model parameters (starting values)
apollo_beta <- c(
  asc_air   = 0,
  asc_train = 0,
  asc_bus   = 0,
  asc_car   = 0,
  b_wait    = 0,
  b_travel  = 0,
  b_cost    = 0
)

# Fix Car as the reference alternative
apollo_fixed <- c("asc_car")

# 9. Validate inputs
apollo_inputs <- apollo_validateInputs()

# 10. Define utility functions and likelihood
apollo_probabilities <- function(apollo_beta, apollo_inputs, functionality = "estimate") {
  
  apollo_attach(apollo_beta, apollo_inputs)
  on.exit(apollo_detach(apollo_beta, apollo_inputs))
  
  P <- list()
  
  # Utility equations (V) for each transport mode
  V <- list()
  V[["air"]]   <- asc_air   + b_wait * wait_air   + b_travel * travel_air   + b_cost * vcost_air
  V[["train"]] <- asc_train + b_wait * wait_train + b_travel * travel_train + b_cost * vcost_train
  V[["bus"]]   <- asc_bus   + b_wait * wait_bus   + b_travel * travel_bus   + b_cost * vcost_bus
  V[["car"]]   <- asc_car   + b_wait * wait_car   + b_travel * travel_car   + b_cost * vcost_car
  
  # Multinomial Logit (MNL) settings
  mnl_settings <- list(
    alternatives  = c(air = 1, train = 2, bus = 3, car = 4),
    avail         = list(air = 1, train = 1, bus = 1, car = 1),
    choiceVar     = choice_id,
    utilities     = V
  )
  
  P[["model"]] <- apollo_mnl(mnl_settings, functionality)
  P <- apollo_prepareProb(P, apollo_inputs, functionality)
  return(P)
}

# 11. Estimate Baseline MNL Model
model_mnl <- apollo_estimate(
  apollo_beta,
  apollo_fixed,
  apollo_probabilities,
  apollo_inputs
)

# 12. Print model results
apollo_modelOutput(model_mnl)
# 13. Extract behavioral & UX indicators from Baseline MNL
est <- model_mnl$estimate
print(round(est, 4))

# Value of In-Vehicle Travel Time (AUD per hour)
vot_travel <- (est["b_travel"] / est["b_cost"]) * 60

# Value of Waiting Time at station/terminal (AUD per hour)
vot_wait <- (est["b_wait"] / est["b_cost"]) * 60

# Psychological Waiting Penalty (1 min waiting = X mins inside vehicle)
wait_penalty <- est["b_wait"] / est["b_travel"]

cat("\n--- Behavioral & UX Findings (Baseline MNL) ---\n")
cat("Value of Travel Time (AUD/hr):", round(vot_travel, 2), "\n")
cat("Value of Waiting Time (AUD/hr):", round(vot_wait, 2), "\n")
cat("Waiting Time Penalty Ratio:", round(wait_penalty, 2), "x\n")
############################################################
# STEP 4: Mixed Logit (MXL) with Socio-Demographic Effects
############################################################

# 14. Re-initialize Apollo for Mixed Logit
apollo_initialise()

database <- sydney_wide

apollo_control <- list(
  modelName       = "Model2_Mixed_Logit",
  modelDescr      = "Mixed Logit with Taste Heterogeneity & Socio-Demographics",
  indivID         = "individual",
  mixing          = TRUE,
  outputDirectory = "output"
)

# 15. Define parameters (random travel time + income & party size)
apollo_beta <- c(
  asc_air        = 0,
  asc_train      = 0,
  asc_bus        = 0,
  asc_car        = 0,
  b_wait         = 0,
  mu_b_travel    = -0.005,
  sigma_b_travel = 0.001,
  b_cost         = 0,
  b_inc_air      = 0,
  b_inc_train    = 0,
  b_inc_bus      = 0,
  b_size_air     = 0,
  b_size_train   = 0,
  b_size_bus     = 0
)

apollo_fixed <- c("asc_car")

# 16. Set up 500 Halton draws for simulation
apollo_draws <- list(
  interDrawsType = "halton",
  interNDraws    = 500,
  interUnifDraws = c(),
  interNormDraws = c("draws_tt"),
  intraDrawsType = "halton",
  intraNDraws    = 0,
  intraUnifDraws = c(),
  intraNormDraws = c()
)

# 17. Define random coefficient for travel time sensitivity
apollo_randCoeff <- function(apollo_beta, apollo_inputs) {
  randcoeff <- list()
  randcoeff[["b_travel"]] <- mu_b_travel + sigma_b_travel * draws_tt
  return(randcoeff)
}

# 18. Validate inputs
apollo_inputs <- apollo_validateInputs()

# 19. Define Mixed Logit probabilities and estimate Model 2
apollo_probabilities_mxl <- function(apollo_beta, apollo_inputs, functionality = "estimate") {
  
  apollo_attach(apollo_beta, apollo_inputs)
  on.exit(apollo_detach(apollo_beta, apollo_inputs))
  
  P <- list()
  
  V <- list()
  V[["air"]]   <- asc_air   + b_wait * wait_air   + b_travel * travel_air   + b_cost * vcost_air   + b_inc_air * income   + b_size_air * size
  V[["train"]] <- asc_train + b_wait * wait_train + b_travel * travel_train + b_cost * vcost_train + b_inc_train * income + b_size_train * size
  V[["bus"]]   <- asc_bus   + b_wait * wait_bus   + b_travel * travel_bus   + b_cost * vcost_bus   + b_inc_bus * income   + b_size_bus * size
  V[["car"]]   <- asc_car   + b_wait * wait_car   + b_travel * travel_car   + b_cost * vcost_car
  
  mnl_settings <- list(
    alternatives  = c(air = 1, train = 2, bus = 3, car = 4),
    avail         = list(air = 1, train = 1, bus = 1, car = 1),
    choiceVar     = choice_id,
    utilities     = V
  )
  
  P[["model"]] <- apollo_mnl(mnl_settings, functionality)
  P <- apollo_avgInterDraws(P, apollo_inputs, functionality)
  P <- apollo_prepareProb(P, apollo_inputs, functionality)
  return(P)
}

model_mxl <- apollo_estimate(
  apollo_beta,
  apollo_fixed,
  apollo_probabilities_mxl,
  apollo_inputs
)

apollo_modelOutput(model_mxl)
############################################################
# STEP 5: Model Comparison, Policy Simulation & Visualization
############################################################

# 20. Formal statistical comparison: Baseline MNL vs. Mixed Logit
cat("\n--- Model Comparison: Likelihood Ratio Test (MNL vs MXL) ---\n")
apollo_lrTest(model_mnl, model_mxl)

# Print clean summary table of MXL estimates & robust t-ratios
mxl_table <- data.frame(
  Parameter   = names(model_mxl$estimate),
  Estimate    = round(model_mxl$estimate, 4),
  Rob_t_ratio = round(model_mxl$estimate / model_mxl$robse, 2)
)
print(mxl_table, row.names = FALSE)

# 21. Policy & UX Counterfactual Simulations (using Model 2: MXL)
get_shares <- function(inputs_obj) {
  pred <- apollo_prediction(
    model_mxl,
    apollo_probabilities_mxl,
    inputs_obj,
    prediction_settings = list(silent = TRUE)
  )
  if (is.list(pred) && !is.data.frame(pred)) pred <- pred[["model"]]
  colMeans(pred[, c("air", "train", "bus", "car")]) * 100
}

# Baseline scenario
shares_base <- get_shares(apollo_inputs)

# Scenario 1: -30% Train Waiting Time (Station UX & Scheduling)
inputs_s1 <- apollo_inputs
inputs_s1$database$wait_train <- inputs_s1$database$wait_train * 0.70
shares_s1 <- get_shares(inputs_s1)

# Scenario 2: -20% Train Ticket Fare (Pricing Policy)
inputs_s2 <- apollo_inputs
inputs_s2$database$vcost_train <- inputs_s2$database$vcost_train * 0.80
shares_s2 <- get_shares(inputs_s2)

# Scenario 3: Combined HSR Package (-30% Train Wait & -20% Train Travel Time)
inputs_s3 <- apollo_inputs
inputs_s3$database$wait_train   <- inputs_s3$database$wait_train * 0.70
inputs_s3$database$travel_train <- inputs_s3$database$travel_train * 0.80
shares_s3 <- get_shares(inputs_s3)

# Combine results into a clean summary table
sim_df <- data.frame(
  Scenario = factor(
    c("Baseline", "-30% Train Wait\n(Station UX)", "-20% Train Fare\n(Pricing)", "HSR Package\n(-30% Wait, -20% Time)"),
    levels = c("Baseline", "-30% Train Wait\n(Station UX)", "-20% Train Fare\n(Pricing)", "HSR Package\n(-30% Wait, -20% Time)")
  ),
  rbind(shares_base, shares_s1, shares_s2, shares_s3),
  row.names = NULL
)

cat("\n--- Predicted Mode Shares (%) Across Policy Scenarios ---\n")
print(sim_df %>% mutate(across(where(is.numeric), ~round(.x, 2))))

# 22. Publication-ready ggplot2 chart & export to output folder
sim_long <- sim_df %>%
  pivot_longer(cols = c(air, train, bus, car), names_to = "Mode", values_to = "Share") %>%
  mutate(Mode = factor(Mode, levels = c("train", "air", "car", "bus"),
                       labels = c("Train", "Air", "Car", "Bus")))

p_sim <- ggplot(sim_long, aes(x = Scenario, y = Share, fill = Mode)) +
  geom_col(position = position_dodge(width = 0.8), width = 0.72) +
  geom_text(
    aes(label = sprintf("%.1f%%", Share)),
    position = position_dodge(width = 0.8),
    vjust = -0.4,
    size = 3.2,
    fontface = "bold"
  ) +
  scale_fill_manual(values = c("Train" = "#2A6F97", "Air" = "#E07A5F", "Car" = "#3D405B", "Bus" = "#81B29A")) +
  ylim(0, max(sim_long$Share) + 8) +
  labs(
    title = "Intercity Mode Share Simulation: Sydney-Melbourne Corridor",
    subtitle = "Counterfactual policy analysis using Mixed Logit (Apollo, N = 210)",
    x = NULL,
    y = "Predicted Mode Share (%)",
    fill = "Transport Mode"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    plot.title = element_text(face = "bold", size = 14),
    plot.subtitle = element_text(color = "grey35", margin = margin(b = 12)),
    legend.position = "top",
    panel.grid.major.x = element_blank()
  )

print(p_sim)

dir.create("output", showWarnings = FALSE)
ggsave("output/policy_simulation_mode_shares.png", plot = p_sim, width = 10, height = 6, dpi = 300, bg = "white")