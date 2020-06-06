#!/bin/bash

set -e
set -o xtrace

PR_NUMBER=$(jq -r ".number" "$GITHUB_EVENT_PATH")

echo "Collecting information about PR #$PR_NUMBER of $GITHUB_REPOSITORY..."

if [[ -z "$GITHUB_TOKEN" ]]; then
	echo "Set the GITHUB_TOKEN env variable."
	exit 1
fi

URI=https://api.github.com
API_HEADER="Accept: application/vnd.github.v3+json"
AUTH_HEADER="Authorization: token $GITHUB_TOKEN"

curl -X DELETE -s \
  -H "${AUTH_HEADER}" \
  -H "${API_HEADER}" \
  "${URI}/repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/labels/needs-rebase"

pr_resp=$(curl -X GET -s -H "${AUTH_HEADER}" -H "${API_HEADER}" \
          "${URI}/repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER")

BASE_REPO=$(echo "$pr_resp" | jq -r .base.repo.full_name)
BASE_BRANCH=$(echo "$pr_resp" | jq -r .base.ref)

USER_LOGIN=$(jq -r ".sender.login" "$GITHUB_EVENT_PATH")

user_resp=$(curl -X GET -s -H "${AUTH_HEADER}" -H "${API_HEADER}" \
            "${URI}/users/${USER_LOGIN}")

USER_NAME=$(echo "$user_resp" | jq -r ".name")
if [[ "$USER_NAME" == "null" ]]; then
	USER_NAME=$USER_LOGIN
fi
USER_NAME="${USER_NAME} (Rebase PR Action)"

USER_EMAIL=$(echo "$user_resp" | jq -r ".email")
if [[ "$USER_EMAIL" == "null" ]]; then
	USER_EMAIL="$USER_LOGIN@users.noreply.github.com"
fi

if [[ "$(echo "$pr_resp" | jq -r .rebaseable)" != "true" ]]; then
	echo "GitHub doesn't think that the PR is rebaseable!"
	echo "API response: $pr_resp"

  curl -X POST -s \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    "${URI}/repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/labels" \
    -d '{"labels": ["need-manual-rebase"]}'

	exit 1
fi

if [[ -z "$BASE_BRANCH" ]]; then
	echo "Cannot get base branch information for PR #$PR_NUMBER!"
	echo "API response: $pr_resp"
	exit 1
fi

HEAD_REPO=$(echo "$pr_resp" | jq -r .head.repo.full_name)
HEAD_BRANCH=$(echo "$pr_resp" | jq -r .head.ref)

echo "Base branch for PR #$PR_NUMBER is $BASE_BRANCH"

echo "HEAD_REPO = $HEAD_REPO"
echo "HEAD_BRANCH = $HEAD_BRANCH"
echo "GITHUB_REPOSITORY = $GITHUB_REPOSITORY"

USER_TOKEN=${USER_LOGIN//-/_}_TOKEN
COMMITTER_TOKEN=${!USER_TOKEN:-$GITHUB_TOKEN}

COMMITTER_TOKEN="$(echo -e "${COMMITTER_TOKEN}" | tr -d '[:space:]')"

git remote

echo "https://x-access-token:$COMMITTER_TOKEN@github.com/$GITHUB_REPOSITORY.git"

git remote set-url origin https://x-access-token:$COMMITTER_TOKEN@github.com/$GITHUB_REPOSITORY.git
git config --global user.email "$USER_EMAIL"
git config --global user.name "$USER_NAME"

echo "https://x-access-token:$COMMITTER_TOKEN@github.com/$HEAD_REPO.git"

git remote add fork https://x-access-token:$COMMITTER_TOKEN@github.com/$HEAD_REPO.git



# make sure branches are up-to-date
git fetch origin $BASE_BRANCH
git fetch fork $HEAD_BRANCH

# do the rebase
git checkout -b $HEAD_BRANCH fork/$HEAD_BRANCH
git rebase origin/$BASE_BRANCH

# push back
git push --force-with-lease fork $HEAD_BRANCH
