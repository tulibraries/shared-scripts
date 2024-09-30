#!/usr/bin/env bash

##
## This script is used to build a requirements.txt from Pipfile and airflow constraints.
## This is a necessary step when trying to rebuild a Pipfile while applying published 
## airflow constraints.
##

# Get Airflow version from Pipfile
AIRFLOW_VERSION=$(pipenv run pip freeze | grep 'apache-airflow==' | cut -d'=' -f3)
if [ "$AIRFLOW_VERSION" = "" ]; then
  AIRFLOW_VERSION=$(grep 'apache-airflow\s*= "==' Pipfile | cut -d' ' -f 3 | sed 's/"==\(.*\)"$/\1/')
fi
echo "Airflow version: $AIRFLOW_VERSION"

# Get Python version from .python-version (first two parts)
PYTHON_VERSION=$(cut -d'.' -f1-2 .python-version)
if [ "$PYTHON_VERSION" = "" ]; then
  PYTHON_VERSION=$(pipenv run python --version | cut -d' ' -f 2)
fi
echo "Python version: $PYTHON_VERSION"

# Download the Airflow constraints file
curl -O https://raw.githubusercontent.com/apache/airflow/constraints-$AIRFLOW_VERSION/constraints-$PYTHON_VERSION.txt

# Generate the list of packages from the Pipfile
packages=$(grep '\w\s*=\s*"==' Pipfile | cut -d= -f1 | sed 's/[[:space:]]*$/==/')

# Create a new empty requirements.txt file
> pipfile-requirements.txt

# Loop through each package and check if it's in the constraints file
while IFS= read -r package; do
  match=$(grep "^$package" "constraints-$PYTHON_VERSION.txt")
  if [ "$match" != "" ]; then
    echo $match >> pipfile-requirements.txt;
  fi
done <<< "$packages"
