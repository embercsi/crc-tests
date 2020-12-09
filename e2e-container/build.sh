#!/usr/bin/env bash

VERSION=${1:-master}

if [[ ! "$VERSION" == "master" ]]; then
    BRANCH="release-$VERSION"
    TAG="$VERSION"
else
    BRANCH=$VERSION
    TAG=latest
fi

CONTAINER_TAG=embercsi/openshift-tests:$TAG

docker build --build-arg BRANCH=$BRANCH -t $CONTAINER_TAG .

echo "To upload execute docker push $CONTAINER_TAG"
