###############################################################################
# The build architecture is select by setting the ARCH variable.
# For example: When building on ppc64le you could use ARCH=ppc64le make <....>.
# When ARCH is undefined it defaults to amd64.
ARCH?=amd64
ifeq ($(ARCH),amd64)
        ARCHTAG?=
endif

ifeq ($(ARCH),ppc64le)
        ARCHTAG:=-ppc64le
endif

.PHONY: all binary test clean help docker-image
default: help

# Makefile configuration options 
CONTAINER_NAME=calico/kube-policy-controller$(ARCHTAG)
PACKAGE_NAME?=github.com/projectcalico/k8s-policy
GO_BUILD_VER:=latest
CALICO_BUILD?=calico/go-build$(ARCHTAG):$(GO_BUILD_VER)
LIBCALICOGO_PATH?=none
LOCAL_USER_ID?=$(shell id -u $$USER)

# Determine which OS.
OS?=$(shell uname -s | tr A-Z a-z)

# Get version from git.
GIT_VERSION?=$(shell git describe --tags --dirty)

###############################################################################
# Build targets 
###############################################################################
## Builds the controller binary and docker image.
docker-image: image.created$(ARCHTAG)
image.created$(ARCHTAG): dist/kube-policy-controller-linux-$(ARCH)
	# Build the docker image for the policy controller.
	docker build -t $(CONTAINER_NAME) -f Dockerfile$(ARCHTAG) .
	touch $@

dist/kube-policy-controller-linux-$(ARCH):
	$(MAKE) OS=linux ARCH=$(ARCH) binary-containerized

## Populates the vendor directory.
vendor: glide.yaml
	# Ensure that the glide cache directory exists.
	mkdir -p $(HOME)/.glide

	# To build without Docker just run "glide install -strip-vendor"
	if [ "$(LIBCALICOGO_PATH)" != "none" ]; then \
          EXTRA_DOCKER_BIND="-v $(LIBCALICOGO_PATH):/go/src/github.com/projectcalico/libcalico-go:ro"; \
	fi; \

	docker run --rm \
		-v $(CURDIR):/go/src/$(PACKAGE_NAME):rw $$EXTRA_DOCKER_BIND \
		-v $(HOME)/.glide:/home/user/.glide:rw \
		-e LOCAL_USER_ID=$(LOCAL_USER_ID) \
		$(CALICO_BUILD) \
		/bin/sh -c 'cd /go/src/$(PACKAGE_NAME) && glide install -strip-vendor'

ut: vendor
	./run-uts

# Build the controller binary.
binary: vendor
	# Don't try to "install" the intermediate build files (.a .o) when not on linux
	# since there are no write permissions for them in our linux build container.
	if [ "$(OS)" == "linux" ]; then \
		INSTALL_FLAG=" -i "; \
	fi; \
	GOOS=$(OS) GOARCH=$(ARCH) CGO_ENABLED=0 go build -v $$INSTALL_FLAG -o dist/kube-policy-controller-$(OS)-$(ARCH) \
	-ldflags "-X main.VERSION=$(GIT_VERSION)" ./main.go

## Build the controller binary in a container.
binary-containerized: vendor
	mkdir -p dist
	-mkdir -p .go-pkg-cache
	docker run --rm \
	  -e OS=$(OS) -e ARCH=$(ARCH) \
	  -v $(CURDIR):/go/src/$(PACKAGE_NAME):ro \
	  -v $(CURDIR)/dist:/go/src/$(PACKAGE_NAME)/dist \
	  -e LOCAL_USER_ID=$(LOCAL_USER_ID) \
	  -v $(CURDIR)/.go-pkg-cache:/go/pkg/:rw \
	  $(CALICO_BUILD) sh -c '\
	    cd /go/src/$(PACKAGE_NAME) && \
	    make OS=$(OS) ARCH=$(ARCH) binary'

###############################################################################
# Test targets 
###############################################################################

## Runs all tests - good for CI. 
ci: clean docker-image check-copyright ut-containerized st 

## Run the tests in a container. Useful for CI, Mac dev.
ut-containerized: vendor 
	-mkdir -p .go-pkg-cache
	docker run --rm --privileged --net=host \
		-e LOCAL_USER_ID=$(LOCAL_USER_ID) \
		-v $(CURDIR)/.go-pkg-cache:/go/pkg/:rw \
		-v $(CURDIR):/go/src/$(PACKAGE_NAME):rw \
		$(CALICO_BUILD) sh -c 'cd /go/src/$(PACKAGE_NAME) && make WHAT=$(WHAT) SKIP=$(SKIP) ut'

GET_CONTAINER_IP := docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
K8S_VERSION=1.7.5

## Runs system tests.
st: docker-image run-etcd run-k8s-apiserver
	./tests/system/apiserver-reconnection.sh $(ARCHTAG)
	$(MAKE) stop-k8s-apiserver stop-etcd

.PHONY: run-k8s-apiserver stop-k8s-apiserver run-etcd stop-etcd
run-k8s-apiserver: stop-k8s-apiserver
	ETCD_IP=`$(GET_CONTAINER_IP) st-etcd` && \
	docker run --detach \
	  --name st-apiserver \
	gcr.io/google_containers/hyperkube-$(ARCH):v$(K8S_VERSION) \
		  /hyperkube apiserver --etcd-servers=http://$${ETCD_IP}:2379 \
		  --service-cluster-ip-range=10.101.0.0/16 -v=10 \
		  --authorization-mode=RBAC

stop-k8s-apiserver:
	@-docker rm -f st-apiserver

run-etcd: stop-etcd
	docker run --detach \
	--name st-etcd quay.io/coreos/etcd:v3.2.5$(ARCHTAG) \
	etcd \
	--advertise-client-urls "http://127.0.0.1:2379,http://127.0.0.1:4001" \
	--listen-client-urls "http://0.0.0.0:2379,http://0.0.0.0:4001"

stop-etcd:
	@-docker rm -f st-etcd

# Make sure that a copyright statement exists on all go files.
check-copyright:
	./check-copyrights.sh 

###############################################################################
# Release targets 
###############################################################################
release: clean
ifndef VERSION
	$(error VERSION is undefined - run using make release VERSION=vX.Y.Z)
endif
	git tag $(VERSION)
	$(MAKE) image.created
	docker tag $(CONTAINER_NAME) $(CONTAINER_NAME):$(VERSION)
	docker tag $(CONTAINER_NAME) quay.io/$(CONTAINER_NAME):$(VERSION)

# Ensure reported version is correct.
	if ! docker run $(CONTAINER_NAME):$(VERSION) version | grep '^$(VERSION)$$'; then echo "Reported version:" `docker run $(CONTAINER_NAME):$(VERSION) version` "\nExpected version: $(VERSION)"; false; else echo "Version check passed\n"; fi

	@echo "Now push the tag and images."
	@echo "git push $(VERSION)"
	@echo "docker push calico/kube-policy-controller:$(VERSION)"
	@echo "docker push quay.io/calico/kube-policy-controller:$(VERSION)"

## Removes all build artifacts.
clean:
	rm -rf dist image.created$(ARCHTAG)
	-docker rmi $(CONTAINER_NAME)
	rm -f st-kubeconfig.yaml

.PHONY: help
## Display this help text.
help: # Some kind of magic from https://gist.github.com/rcmachado/af3db315e31383502660
	$(info Available targets)
	@awk '/^[a-zA-Z\-\_0-9\/]+:/ {                                      \
		nb = sub( /^## /, "", helpMsg );                                \
		if(nb == 0) {                                                   \
			helpMsg = $$0;                                              \
			nb = sub( /^[^:]*:.* ## /, "", helpMsg );                   \
		}                                                               \
		if (nb)                                                         \
			printf "\033[1;31m%-" width "s\033[0m %s\n", $$1, helpMsg;  \
	}                                                                   \
	{ helpMsg = $$0 }'                                                  \
	width=20                                                            \
	$(MAKEFILE_LIST)

###############################################################################
# Utilities 
###############################################################################

goimports:
	goimports -l -w ./pkg
	goimports -l -w ./main.go
