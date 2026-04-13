#!/bin/bash
yaml="test.yaml"
cat << 'IN' > "$yaml"
dependencies:
  flutter:
    sdk: flutter
  http: ^0.13.3
  intl: ">=0.17.0 <0.18.0"
  path: 1.8.0
  provider:
    version: ^6.0.0
  shared_preferences:
IN

pkg="provider"
version=$(grep -A1 "^  $pkg:" "$yaml" | grep -v "^  $pkg:" | grep "version:" | awk '{print $2}' | tr -d '"'\''\^>=~<')
if [ -z "$version" ]; then
   version=$(grep "^  $pkg:" "$yaml" | awk '{print $2}' | tr -d '"'\''\^>=~<')
fi
version=$(echo "$version" | awk '{print $1}')
echo "provider: $version"

pkg="http"
version=$(grep -A1 "^  $pkg:" "$yaml" | grep -v "^  $pkg:" | grep "version:" | awk '{print $2}' | tr -d '"'\''\^>=~<')
if [ -z "$version" ]; then
   version=$(grep "^  $pkg:" "$yaml" | awk '{print $2}' | tr -d '"'\''\^>=~<')
fi
version=$(echo "$version" | awk '{print $1}')
echo "http: $version"

pkg="shared_preferences"
version=$(grep -A1 "^  $pkg:" "$yaml" | grep -v "^  $pkg:" | grep "version:" | awk '{print $2}' | tr -d '"'\''\^>=~<')
if [ -z "$version" ]; then
   version=$(grep "^  $pkg:" "$yaml" | cut -d: -f2 | xargs | awk '{print $1}' | tr -d '"'\''\^>=~<')
fi
version=$(echo "$version" | awk '{print $1}')
echo "shared_preferences: $version"

