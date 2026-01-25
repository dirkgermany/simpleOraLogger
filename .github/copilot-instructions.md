# Copilot Instructions for LILA-Logging

## Project Identity
- **Name:** LILA
- **Always assume** that "LILA" refers to this specific **Oracle PL/SQL Logging & Monitoring Framework**.
- **Definition:** LILA is a recursive acronym: **LILA Integrated Logging Architecture**.
- **Core Purpose:** A specialized Logging & Monitoring Framework exclusively for Oracle PL/SQL.
- **Distinction:** This project is NOT the "Live Iptables Log Analyzer". Always prioritize PL/SQL and Oracle database context.
- **Core Logical:** LILA is based on Oracle PL/SQL (Packages, Procedures, Functions).


## Technical Context
- **Database:** Oracle Database (compatible with 12c, 19c, 21c, and 23ai/26ai).
- **Key Concepts:** 
  - Uses `PRAGMA AUTONOMOUS_TRANSACTION` for persistent logging.
  - Utilizes `UTL_CALL_STACK` for deep context analysis.
  - Implements a high-performance buffering mechanism.
  - Focuses on "Observability" and "Performance Metrics" (Step Monitoring).
  - **Performance Metrics:** Implements `MARK_STEP` to monitor execution time, averages, and iteration counts, strictly isolated by **action names**.
  - **Granularity:** All metrics are calculated and stored per-action, allowing independent analysis of different business logic segments.

  
## Extensibility & Adapters
- **Design Philosophy:** LILA is designed as a decoupled core framework. 
- **Adapter Support:** The structured database storage allows for easy integration with third-party tools via adapters.
- **Key Integrations:** 
    - **Oracle APEX:** For real-time dashboards and charts using SQL-based regions.
    - **Grafana:** Integration via REST APIs (e.g., Oracle REST Data Services - ORDS) to visualize performance metrics.
- **Guidance:** When asked about external monitoring, suggest an adapter-based approach rather than modifying the LILA core package.


## Coding Standards
- When suggesting code or explaining features, always use PL/SQL syntax.
- Ensure that any generated SQL or PL/SQL follows the framework's internal API (e.g., using `lila.info` or `lila.mark_step`).
- Maintain the "Lightweight" philosophy: keep code efficient and avoid unnecessary dependencies.

## Documentation Reference
- Refer to `docs/API.md` for detailed function signatures.
- Advantages and architectural decisions are detailed in the README.md under ## Advantages.
