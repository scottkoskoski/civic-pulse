# data-engineering/config/__init__.py
"""
Configuration package for Memphis Data Pipeline.

This package contains all configuration settings organized by concern:
    - database.py: Database connection and schema settings
    - sources.py: Data source endpoints and API configuration
    - settings.py: General application settings and constants

Usage:
    from config.database import get_connection
    from config.sources import MEMPHIS_CRIME_API
    from config.settings import PROJECT_NAME
"""

__version__ = "0.1.0"
__author__ = "Scott Koskoski"
