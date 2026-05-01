# Hybrid Pitch and BESS Control for Wind Power Smoothing

## Usage
This repository is provided for academic reference only.  
The work is original and should not be copied or submitted as your own.

## Project Overview
This project develops a hybrid control system combining battery energy storage (BESS) and turbine pitch control to smooth offshore wind power output. The model is implemented in MATLAB and Simulink and evaluated using real-world wind data.

The main objective is to reduce ramp-rate violations and improve power output stability under grid constraints.

---

## Model Structure

The project consists of two main components:

### 1. MATLAB Script
The MATLAB script is used for:
- Importing and processing wind data from CSV files
- Converting wind speed into turbine and wind farm power output
- Selecting specific time windows (scenarios)
- Running sensitivity analysis across:
  - Battery sizes (power and energy)
  - Ramp-rate limits
- Exporting results and generating performance metrics

Users can modify:
- Time period (start date and duration)
- Ramp-rate constraints
- Battery parameters (power, energy, SOC limits)

---

### 2. Simulink Model
The Simulink model (`wind_control.slx`) performs the main simulation:

It includes:
- Wind turbine power conversion (simplified aerodynamic model)
- Moving average filtering (target power)
- Ramp-rate limiting
- Battery energy storage system (BESS):
  - Bidirectional smoothing
  - SOC management
  - Power limits
- Pitch control:
  - Curtailment during oversupply
- Hybrid control logic:
  - Battery acts as primary control
  - Pitch activates when battery limits are reached

---

## Key Features

- Scenario-based simulation (user-defined time window)
- Adjustable ramp-rate constraints (%/min)
- Flexible battery sizing (MW / MWh)
- Comparison of three control strategies:
  - Pitch-only
  - BESS-only
  - Hybrid control
- Performance metrics:
  - Ramp-rate violations (%)
  - RMS ramp rate
  - Residual error
  - Battery utilisation
  - Curtailment energy
- Sensitivity analysis across multiple system configurations

---

## How to Use

1. Open MATLAB
2. Load the main script (`setup_wind_data.m`)
3. Ensure the CSV dataset is correctly linked:
   - Update file path if needed
4. Select scenario parameters:
   - Time window (start date)
   - Duration
5. Run the script

The script will:
- Process wind data
- Run Simulink simulations
- Output results and figures

---

## Important Notes

- The Simulink model runs **one configuration at a time**
  (single battery size and ramp-rate)
- Sensitivity analysis is handled in MATLAB through looped simulations
- Large datasets are not included; sample data is provided
- The model uses simplified assumptions:
  - Ideal battery efficiency
  - Simplified turbine power curve
  - No wake effects or spatial variability

---

## Purpose

This repository is provided to:
- Support reproducibility of the project
- Demonstrate implementation of hybrid smoothing control
- Provide a reference model for further research

---

## Author
Yefym Lunov – 3rd Year Engineering Project# wind-power-smoothing-bess-pitch
