#! /bin/bash
# This script synch master branch with remote staging branch
# We can certainly use a parameter for this script
# to add a remote upstream, use the following git command
# git remote add upstream https://github.com/ORIGINAL_OWNER/ORIGINAL_REPOSITORY.git

# Setup some colors
ColorOff='\033[0m'       # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green

set -e
branch=$1
if [ -z "$branch" ]; then
   echo "Branch is not provided, default to master"
   branch=master
fi

echo -e "Ready to sync ${Green}${branch}${ColorOff} branch with upstream "$Green$branch$ColorOff

read -p "Continue (y/n) ? " -n 1 -r
echo    # (optional) move to a new line
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    exit 1
fi
git fetch upstream $branch
git reset --hard upstream/$branch
git checkout $branch
git merge upstream/$branch
git push --force
