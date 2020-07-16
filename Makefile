SHELL := bash
.SHELLFLAGS = -ec

DEVWORKSPACE_API_VERSION ?= master
DEVWORKSPACE_OPERATOR_VERSION ?= master
BUNDLE_IMG ?=
INDEX_IMG ?=

.ONESHELL:
all: help

_print_vars:
	@echo "Current env vars:"
	echo "    DEVWORKSPACE_API_VERSION=$(DEVWORKSPACE_API_VERSION)"
	echo "    DEVWORKSPACE_OPERATOR_VERSION=$(DEVWORKSPACE_OPERATOR_VERSION)"
	echo "    BUNDLE_IMG=$(BUNDLE_IMG)"
	echo "    INDEX_IMG=$(INDEX_IMG)"
### update_dependencies: updates files from DevWorkspace API and Operators
update_dependencies:
	./update-dependencies.sh

### gen_terminal_csv: generate the csv for a newer version. Refer to gen_terminal_csv makefile definition for extra manual steps that are needed.
gen_terminal_csv : update_dependencies
	# Remove everything in manifests except CSV which contains manually filled
	# fields, like description, puslisher, ...
	find ./manifests -type f -not -name 'web-terminal.clusterserviceversion.yaml' -delete

	# Need to be in root of the controller in order to run operator-sdk
	pushd devworkspace-dependencies > /dev/null
	operator-sdk generate csv --apis-dir ./pkg/apis --csv-version 1.0.0 --make-manifests --update-crds --operator-name "web-terminal" --output-dir ../
	popd > /dev/null

### build: build the terminal bundle and index and push them to a docker registry
build: _print_vars _check_imgs_env _check_skopeo_installed
	rm -rf ./generated
	# Create the bundle and push it to a docker registry
	@operator-sdk bundle create $(BUNDLE_IMG) --channels alpha --package web-terminal --directory ./manifests --overwrite --output-dir generated
	docker push $(BUNDLE_IMG)

	BUNDLE_DIGEST=$$(skopeo inspect docker://$(BUNDLE_IMG) | jq -r '.Digest')
	BUNDLE_IMG_DIGEST="$${BUNDLE_IMG%:*}@$${BUNDLE_DIGEST}"
	# create / update and push an index that contains the bundle
	opm index add -c docker --bundles $${BUNDLE_IMG_DIGEST} --tag $(INDEX_IMG)
	docker push $(INDEX_IMG)

### export: export the bundles stored in the index to the exported-manifests folder
export: _print_vars _check_imgs_env
	rm -rf ./exported-manifests
	# Export the bundles with the name web-terminal inside of $(INDEX_IMG)
	# This command basic exports the index back into the old format
	opm index export -c docker -f exported-manifests -i $(INDEX_IMG) -o web-terminal

### register_catalogsource: creates the catalogsource to make the operator be available on the marketplace. Must have $(INDEX_IMG) available on docker registry already and have it set to public
register_catalogsource: _print_vars _check_imgs_env _check_skopeo_installed
	# replace references of catalogsource img with your image
	@INDEX_DIGEST=$$(skopeo inspect docker://$(INDEX_IMG) | jq -r '.Digest')
	INDEX_IMG_DIGEST="$${INDEX_IMG%:*}@$${INDEX_DIGEST}"

	sed -i.bak -e "s|quay.io/che-incubator/che-workspace-operator-index:latest|$${INDEX_IMG_DIGEST}|g" ./catalog-source.yaml
	oc apply -f ./catalog-source.yaml
	mv ./catalog-source.yaml.bak ./catalog-source.yaml

### build_install: build the catalog and create catalogsource and operator subscription on the cluster
build_install: _print_vars build install

### install: creates catalog source along with operator subscription on the cluster
install: _print_vars register_catalogsource
	oc apply -f ./operator-subscription.yaml

### uninstall: uninstalls the catalog source along with operator subscription
uninstall:
	oc delete subscriptions.operators.coreos.com web-terminal -n openshift-operators --ignore-not-found=true
	oc delete csv web-terminal.v1.0.0 -n openshift-operators --ignore-not-found=true
	echo "Note additional steps required for a full uninstall -- clusterroles, services, and CRDs remain on the cluster"

_check_imgs_env:
ifndef BUNDLE_IMG
	$(error "BUNDLE_IMG not set")
endif
ifndef INDEX_IMG
	$(error "INDEX_IMG not set")
endif

_check_skopeo_installed:
ifeq ($(shell command -v kubectl 2> /dev/null),)
	$(error "skopeo is required for building and deploying bundle, but is not installed")
endif

.PHONY: help
### help: print this message
help: Makefile
	@echo 'Available rules:'
	sed -n 's/^### /    /p' $< | awk 'BEGIN { FS=":" } { printf "%-32s -%s\n", $$1, $$2 }'
	echo ''
	echo 'Supported environment variables:'
	echo '    DEVWORKSPACE_API_VERSION       - Branch or tag of the github.com/devfile/kubernetes-api to depend on. Set to $(DEVWORKSPACE_API_VERSION)'
	echo '    DEVWORKSPACE_OPERATOR_VERSION  - The branch/tag of the terminal manifests. Set to $(DEVWORKSPACE_OPERATOR_VERSION)'
	echo '    BUNDLE_IMG                     - The name of the olm registry bundle image. Set to $(BUNDLE_IMG)'
	echo '    INDEX_IMG                      - The name of the olm registry index image. Set to $(INDEX_IMG)'
