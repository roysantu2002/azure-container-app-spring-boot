#!/bin/bash
# Run against LOCAL Docker PostgreSQL
cd "$(dirname "$0")/application"
SPRING_PROFILES_ACTIVE=local mvn spring-boot:run
