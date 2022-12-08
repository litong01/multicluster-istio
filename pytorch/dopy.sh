#!/bin/bash
# This script creates a volume and start pytorch

# check if mypy volume exist, if not, create one with 1gb
name=$(docker volume inspect mypy -f "{{ .Name }}"  2>/dev/null)
if [[ -z "$name" ]]; then
  docker volume create --name mypy
  #  --opt type=tmpfs --opt device=tmpfs --opt o=size=1000m,uid=1000
else
  echo "Volume exists already!"
fi

container=$(docker inspect pytorch -f "{{ .Name}}" 2>/dev/null)
if [[ ! -z "$container" ]]; then
  echo "removing the existing container..."
  docker rm -f pytorch
fi

echo "Starting pytorch..."
docker run --rm -dit --name pytorch -v mypy:/workspace \
  pytorch/pytorch:latest


