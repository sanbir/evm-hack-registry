#!/bin/bash

# Parse input parameters from the command line
FILENAME=$1

# Construct the URL with the input filename
URL="https://raw.githubusercontent.com/rhinestonewtf/femplate/main/$FILENAME"

# Use wget to download the file from the constructed URL
wget $URL
