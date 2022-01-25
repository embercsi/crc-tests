# Example: docker build --build-arg BRANCH=release-4.5

# We use centos instead of a slimmer container because we need it to be
# compatible with the oc binary that's installed on the centos openshift VM.
FROM centos:7 AS builder
ARG BRANCH=master
COPY . /root
RUN yum -y install git gcc libc-dev && \
    curl -Lo go.tar.gz https://dl.google.com/go/go1.14.2.linux-amd64.tar.gz && \
    tar -zxf go.tar.gz && \
    rm go.tar.gz && \
    mv go /usr/local && \
    export GOROOT=/usr/local/go && \
    mkdir /root/go && \
    export GOPATH=/root/go && \
    export PATH=$GOPATH/bin:$GOROOT/bin:$PATH && \
    mkdir -p ${GOPATH}/src/github.com/openshift/ && \
    cd ${GOPATH}/src/github.com/openshift/ && \
    git clone --depth=1 -b ${BRANCH} https://github.com/openshift/openshift-tests.git && \
    cd openshift-tests && \
    sed -i 's#> /mnt/test/initialData# & \&\& sync /mnt/test/initialData#g' vendor/k8s.io/kubernetes/test/e2e/storage/testsuites/provisioning.go && \
    go build -o cmd/extended-platform-tests -mod vendor ./cmd/extended-platform-tests && \
    useradd -u 1000 vagrant

FROM centos:7
COPY --from=builder /root/filter-tests.py /root/run-tests.sh /root/go/src/github.com/openshift/openshift-tests/cmd/extended-platform-tests/extended-platform-tests /root/
RUN useradd -u 1000 vagrant
WORKDIR /root/
ENTRYPOINT ["./run-tests.sh"]
