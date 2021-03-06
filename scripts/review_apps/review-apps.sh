[[ "$TRACE" ]] && set -x
export TILLER_NAMESPACE="$KUBE_NAMESPACE"

function echoerr() { printf "\033[0;31m%s\n\033[0m" "$*" >&2; }

function check_kube_domain() {
  if [ -z ${REVIEW_APPS_DOMAIN+x} ]; then
    echo "In order to deploy or use Review Apps, REVIEW_APPS_DOMAIN variable must be set"
    echo "You can do it in Auto DevOps project settings or defining a variable at group or project level"
    echo "You can also manually add it in .gitlab-ci.yml"
    false
  else
    true
  fi
}

function download_gitlab_chart() {
  curl -o gitlab.tar.bz2 https://gitlab.com/charts/gitlab/-/archive/$GITLAB_HELM_CHART_REF/gitlab-$GITLAB_HELM_CHART_REF.tar.bz2
  tar -xjf gitlab.tar.bz2
  cd gitlab-$GITLAB_HELM_CHART_REF

  helm init --client-only
  helm repo add gitlab https://charts.gitlab.io
  helm dependency update
  helm dependency build
}

function ensure_namespace() {
  kubectl describe namespace "$KUBE_NAMESPACE" || kubectl create namespace "$KUBE_NAMESPACE"
}

function install_tiller() {
  echo "Checking Tiller..."
  helm init --upgrade
  kubectl rollout status -n "$TILLER_NAMESPACE" -w "deployment/tiller-deploy"
  if ! helm version --debug; then
    echo "Failed to init Tiller."
    return 1
  fi
  echo ""
}

function create_secret() {
  echo "Create secret..."

  kubectl create secret generic -n "$KUBE_NAMESPACE" \
    $CI_ENVIRONMENT_SLUG-gitlab-initial-root-password \
    --from-literal=password=$REVIEW_APPS_ROOT_PASSWORD \
    --dry-run -o json | kubectl apply -f -
}

function deployExists() {
  local namespace="${1}"
  local deploy="${2}"
  helm status --tiller-namespace "${namespace}" "${deploy}" >/dev/null 2>&1
  return $?
}

function previousDeployFailed() {
  set +e
  deploy="${1}"
  echo "Checking for previous deployment of ${deploy}"
  deployment_status=$(helm status ${deploy} >/dev/null 2>&1)
  status=$?
  # if `status` is `0`, deployment exists, has a status
  if [ $status -eq 0 ]; then
    echo "Previous deployment found, checking status"
    deployment_status=$(helm status ${deploy} | grep ^STATUS | cut -d' ' -f2)
    echo "Previous deployment state: $deployment_status"
    if [[ "$deployment_status" == "FAILED" || "$deployment_status" == "PENDING_UPGRADE" || "$deployment_status" == "PENDING_INSTALL" ]]; then
      status=0;
    else
      status=1;
    fi
  else
    echo "Previous deployment NOT found."
  fi
  set -e
  return $status
}

function deploy() {
  track="${1-stable}"
  name="$CI_ENVIRONMENT_SLUG"

  if [[ "$track" != "stable" ]]; then
    name="$name-$track"
  fi

  replicas="1"
  service_enabled="false"
  postgres_enabled="$POSTGRES_ENABLED"

  IMAGE_REPOSITORY="registry.gitlab.com/gitlab-org/build/cng-mirror"
  IMAGE_VERSION="${CI_PROJECT_NAME#gitlab-}"
  gitlab_migrations_image_repository="${IMAGE_REPOSITORY}/gitlab-rails-${IMAGE_VERSION}"
  gitlab_sidekiq_image_repository="${IMAGE_REPOSITORY}/gitlab-sidekiq-${IMAGE_VERSION}"
  gitlab_unicorn_image_repository="${IMAGE_REPOSITORY}/gitlab-unicorn-${IMAGE_VERSION}"
  gitlab_task_runner_image_repository="${IMAGE_REPOSITORY}/gitlab-task-runner-${IMAGE_VERSION}"
  gitlab_gitaly_image_repository="${IMAGE_REPOSITORY}/gitaly"
  gitlab_shell_image_repository="${IMAGE_REPOSITORY}/gitlab-shell"
  gitlab_workhorse_image_repository="${IMAGE_REPOSITORY}/gitlab-workhorse-${IMAGE_VERSION}"

  # canary uses stable db
  [[ "$track" == "canary" ]] && postgres_enabled="false"

  env_track=$( echo $track | tr -s  '[:lower:]'  '[:upper:]' )
  env_slug=$( echo ${CI_ENVIRONMENT_SLUG//-/_} | tr -s  '[:lower:]'  '[:upper:]' )

  if [[ "$track" == "stable" ]]; then
    # for stable track get number of replicas from `PRODUCTION_REPLICAS`
    eval new_replicas=\$${env_slug}_REPLICAS
    service_enabled="true"
  else
    # for all tracks get number of replicas from `CANARY_PRODUCTION_REPLICAS`
    eval new_replicas=\$${env_track}_${env_slug}_REPLICAS
  fi
  if [[ -n "$new_replicas" ]]; then
    replicas="$new_replicas"
  fi

  # Cleanup and previous installs, as FAILED and PENDING_UPGRADE will cause errors with `upgrade`
  if [ "$CI_ENVIRONMENT_SLUG" != "production" ] && previousDeployFailed "$CI_ENVIRONMENT_SLUG" ; then
    echo "Deployment in bad state, cleaning up $CI_ENVIRONMENT_SLUG"
    delete
    cleanup
  fi

  create_secret

  helm repo add gitlab https://charts.gitlab.io/
  helm dep update .

HELM_CMD=$(cat << EOF
  helm upgrade --install \
    --wait \
    --timeout 600 \
    --set global.appConfig.enableUsagePing=false \
    --set releaseOverride="$CI_ENVIRONMENT_SLUG" \
    --set global.hosts.hostSuffix="$HOST_SUFFIX" \
    --set global.hosts.domain="$REVIEW_APPS_DOMAIN" \
    --set certmanager.install=false \
    --set global.ingress.configureCertmanager=false \
    --set global.ingress.tls.secretName=tls-cert \
    --set global.ingress.annotations."external-dns\.alpha\.kubernetes\.io/ttl"="10"
    --set gitlab.unicorn.resources.requests.cpu=200m \
    --set gitlab.sidekiq.resources.requests.cpu=100m \
    --set gitlab.gitlab-shell.resources.requests.cpu=100m \
    --set redis.resources.requests.cpu=100m \
    --set minio.resources.requests.cpu=100m \
    --set gitlab.migrations.image.repository="$gitlab_migrations_image_repository" \
    --set gitlab.migrations.image.tag="$CI_COMMIT_REF_NAME" \
    --set gitlab.sidekiq.image.repository="$gitlab_sidekiq_image_repository" \
    --set gitlab.sidekiq.image.tag="$CI_COMMIT_REF_NAME" \
    --set gitlab.unicorn.image.repository="$gitlab_unicorn_image_repository" \
    --set gitlab.unicorn.image.tag="$CI_COMMIT_REF_NAME" \
    --set gitlab.task-runner.image.repository="$gitlab_task_runner_image_repository" \
    --set gitlab.task-runner.image.tag="$CI_COMMIT_REF_NAME" \
    --set gitlab.gitaly.image.repository="registry.gitlab.com/gitlab-org/build/cng-mirror/gitaly" \
    --set gitlab.gitaly.image.tag="v$GITALY_VERSION" \
    --set gitlab.gitlab-shell.image.repository="registry.gitlab.com/gitlab-org/build/cng-mirror/gitlab-shell" \
    --set gitlab.gitlab-shell.image.tag="v$GITLAB_SHELL_VERSION" \
    --set gitlab.unicorn.workhorse.image="$gitlab_workhorse_image_repository" \
    --set gitlab.unicorn.workhorse.tag="$CI_COMMIT_REF_NAME" \
    --set nginx-ingress.controller.config.ssl-ciphers="ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA:ECDHE-RSA-AES128-SHA:AES256-GCM-SHA384:AES128-GCM-SHA256:AES256-SHA256:AES128-SHA256:AES256-SHA:AES128-SHA:!aNULL:!eNULL:!EXPORT:!DES:!MD5:!PSK:!RC4" \
    --namespace="$KUBE_NAMESPACE" \
    --version="$CI_PIPELINE_ID-$CI_JOB_ID" \
    "$name" \
    .
EOF
)

  echo "Deploying with:"
  echo $HELM_CMD

  eval $HELM_CMD
}

function delete() {
  track="${1-stable}"
  name="$CI_ENVIRONMENT_SLUG"

  if [ -z "$CI_ENVIRONMENT_SLUG" ]; then
    echo "No release given, aborting the delete!"
    return
  fi

  if [[ "$track" != "stable" ]]; then
    name="$name-$track"
  fi

  if ! deployExists "${KUBE_NAMESPACE}" "${name}"; then
    echo "The release $name doesn't exist, aborting the cleanup!"
    return
  fi

  echo "Deleting release '$name'..."
  helm delete --purge "$name" || true
}

function cleanup() {
  if [ -z "$CI_ENVIRONMENT_SLUG" ]; then
    echo "No release given, aborting the delete!"
    return
  fi

  echo "Cleaning up '$CI_ENVIRONMENT_SLUG'..."
  kubectl -n "$KUBE_NAMESPACE" delete \
    ingress,svc,pdb,hpa,deploy,statefulset,job,pod,secret,configmap,pvc,secret,clusterrole,clusterrolebinding,role,rolebinding,sa \
    -l release="$CI_ENVIRONMENT_SLUG" \
  || true
}

function install_external_dns() {
  local release_name="dns-gitlab-review-app"
  local domain=$(echo "${REVIEW_APPS_DOMAIN}" | awk -F. '{printf "%s.%s", $(NF-1), $NF}')

  if ! deployExists "${KUBE_NAMESPACE}" "${release_name}" || previousDeployFailed "${release_name}" ; then
    echo "Installing external-dns helm chart"
    helm repo update
    helm install stable/external-dns \
      -n "${release_name}" \
      --namespace "${KUBE_NAMESPACE}" \
      --set provider="aws" \
      --set aws.secretKey="${REVIEW_APPS_AWS_SECRET_KEY}" \
      --set aws.accessKey="${REVIEW_APPS_AWS_ACCESS_KEY}" \
      --set aws.zoneType="public" \
      --set domainFilters[0]="${domain}" \
      --set txtOwnerId="${KUBE_NAMESPACE}" \
      --set rbac.create="true"
  fi
}

function get_pod() {
  local app_name="${1}"
  local status="${2-Running}"
  get_pod_cmd="kubectl get pods -n ${KUBE_NAMESPACE} --field-selector=status.phase=${status} -lapp=${app_name},release=${CI_ENVIRONMENT_SLUG} --no-headers -o=custom-columns=NAME:.metadata.name"
  echoerr "Running '${get_pod_cmd}'"

  while true; do
    local pod_name="$(eval $get_pod_cmd)"
    [[ "${pod_name}" == "" ]] || break

    echoerr "Waiting till '${app_name}' pod is ready";
    sleep 5;
  done

  echoerr "The pod name is '${pod_name}'."
  echo "${pod_name}"
}

function add_license() {
  if [ -z "${REVIEW_APPS_EE_LICENSE}" ]; then echo "License not found" && return; fi

  task_runner_pod=$(get_pod "task-runner");
  if [ -z "${task_runner_pod}" ]; then echo "Task runner pod not found" && return; fi

  echo "${REVIEW_APPS_EE_LICENSE}" > /tmp/license.gitlab
  kubectl -n "$KUBE_NAMESPACE" cp /tmp/license.gitlab ${task_runner_pod}:/tmp/license.gitlab
  rm /tmp/license.gitlab

  kubectl -n "$KUBE_NAMESPACE" exec -it ${task_runner_pod} -- /srv/gitlab/bin/rails runner -e production \
    '
    content = File.read("/tmp/license.gitlab").strip;
    FileUtils.rm_f("/tmp/license.gitlab");

    unless License.where(data:content).empty?
      puts "License already exists";
      Kernel.exit 0;
    end

    unless License.new(data: content).save
      puts "Could not add license";
      Kernel.exit 0;
    end

    puts "License added";
    '
}

function get_job_id() {
  local job_name="${1}"
  local query_string="${2:+&${2}}"

  local max_page=3
  local page=1

  while true; do
    local url="https://gitlab.com/api/v4/projects/${CI_PROJECT_ID}/pipelines/${CI_PIPELINE_ID}/jobs?per_page=100&page=${page}${query_string}"
    echoerr "GET ${url}"

    local job_id=$(curl --silent --show-error --header "PRIVATE-TOKEN: ${API_TOKEN}" "${url}" | jq ".[] | select(.name == \"${job_name}\") | .id")
    [[ "${job_id}" == "" && "${page}" -lt "$max_page" ]] || break

    ((page++))
  done

  if [[ "${job_id}" == "" ]]; then
    echoerr "The '${job_name}' job ID couldn't be retrieved!"
  else
    echoerr "The '${job_name}' job ID is ${job_id}"
    echo "${job_id}"
  fi
}

function play_job() {
  local job_name="${1}"
  local job_id=$(get_job_id "${job_name}" "scope=manual");
  if [ -z "${job_id}" ]; then return; fi

  local url="https://gitlab.com/api/v4/projects/${CI_PROJECT_ID}/jobs/${job_id}/play"
  echoerr "POST ${url}"

  local job_url=$(curl --silent --show-error --request POST --header "PRIVATE-TOKEN: ${API_TOKEN}" "${url}" | jq ".web_url")
  echo "Manual job '${job_name}' started at: ${job_url}"
}

function wait_for_job_to_be_done() {
  local job_name="${1}"
  local query_string="${2}"
  local job_id=$(get_job_id "${job_name}" "${query_string}");
  if [ -z "${job_id}" ]; then return; fi

  echoerr "Waiting for the '${job_name}' job to finish..."

  local url="https://gitlab.com/api/v4/projects/${CI_PROJECT_ID}/jobs/${job_id}"
  echo "GET ${url}"

  # In case the job hasn't finished yet. Keep trying until the job times out.
  local interval=30
  local elapsed=0
  while true; do
    local job_status=$(curl --silent --show-error --header "PRIVATE-TOKEN: ${API_TOKEN}" "${url}" | jq ".status" | sed -e s/\"//g)
    [[ "${job_status}" == "pending" || "${job_status}" == "running" ]] || break

    printf "."
    ((elapsed+=$interval))
    sleep ${interval}
  done

  echoerr "Waited '${job_name}' for ${elapsed} seconds."

  if [[ "${job_status}" == "failed" ]]; then
    echo "The '${job_name}' failed."
  elif [[ "${job_status}" == "manual" ]]; then
    echo "The '${job_name}' is manual."
  else
    echo "The '${job_name}' passed."
  fi
}
