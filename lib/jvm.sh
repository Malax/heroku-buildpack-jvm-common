#!/usr/bin/env bash

# This script provides common utilities for installing the JDK and JRE. It is used
# by both the v2 and v3 buildpacks.

STACK="${STACK:-$CNB_STACK_ID}"
DEFAULT_JDK_VERSION="1.8"
DEFAULT_JDK_1_7_VERSION="1.7.0_252"
DEFAULT_JDK_1_8_VERSION="1.8.0_242"
DEFAULT_JDK_1_9_VERSION="9.0.4"
DEFAULT_JDK_10_VERSION="10.0.2"
DEFAULT_JDK_11_VERSION="11.0.6"
DEFAULT_JDK_12_VERSION="12.0.2"
DEFAULT_JDK_13_VERSION="13.0.2"
DEFAULT_JDK_BASE_URL="https://lang-jvm.s3.amazonaws.com/jdk/${STACK:-"heroku-18"}"
JDK_BASE_URL=${JDK_BASE_URL:-$DEFAULT_JDK_BASE_URL}

get_jdk_version() {
  local appDir="${1:?}"
  if [ -f ${appDir}/system.properties ]; then
    detectedVersion="$(_get_system_property "${appDir}/system.properties" "java.runtime.version")"
    if [ -n "$detectedVersion" ]; then
      echo "$detectedVersion"
    else
      echo "$DEFAULT_JDK_VERSION"
    fi
  else
    echo "$DEFAULT_JDK_VERSION"
  fi
}

get_full_jdk_version() {
  local jdkVersion="${1:?}"

  if [ "${jdkVersion}" = "10" ]; then
    echo "$DEFAULT_JDK_10_VERSION"
  elif [ "${jdkVersion}" = "11" ]; then
    echo "$DEFAULT_JDK_11_VERSION"
  elif [ "${jdkVersion}" = "12" ]; then
    echo "$DEFAULT_JDK_12_VERSION"
  elif [ "${jdkVersion}" = "13" ]; then
    echo "$DEFAULT_JDK_13_VERSION"
  elif [ "$(expr "${jdkVersion}" : '^1.[6-9]$')" != 0 ]; then
    local minorJdkVersion=$(expr "${jdkVersion}" : '1.\([6-9]\)')
    echo "$(eval echo \$DEFAULT_JDK_1_${minorJdkVersion}_VERSION)"
  elif [ "$(expr "${jdkVersion}" : '^[6-9]$')" != 0 ]; then
    echo "$(eval echo \$DEFAULT_JDK_1_${jdkVersion}_VERSION)"
  elif [ "${jdkVersion}" = "9+181" ] || [ "${jdkVersion}" = "9.0.0" ]; then
    echo "9-181" # the naming convention for the first JDK 9 release was poor
  else
    echo "$jdkVersion"
  fi
}

get_jdk_url() {
  local shortJdkVersion=${1:-${DEFAULT_JDK_VERSION}}
  local jdkVersion="$(get_full_jdk_version "${shortJdkVersion}")"

  if [ "$(expr "${jdkVersion}" : '^1[0-3]')" != 0 ]; then
    local jdkUrl="${JDK_BASE_URL}/openjdk${jdkVersion}.tar.gz"
  elif [ "$(expr "${jdkVersion}" : '^1.[6-9]')" != 0 ]; then
    local jdkUrl="${JDK_BASE_URL}/openjdk${jdkVersion}.tar.gz"
  elif [ "${jdkVersion}" = "9+181" ] || [ "${jdkVersion}" = "9.0.0" ]; then
    local jdkUrl="${JDK_BASE_URL}/openjdk9-181.tar.gz"
  elif [ "$(expr "${jdkVersion}" : '^9')" != 0 ]; then
    local jdkUrl="${JDK_BASE_URL}/openjdk${jdkVersion}.tar.gz"
  elif [ "$(expr "${jdkVersion}" : '^zulu-')" != 0 ]; then
    local jdkUrl="${JDK_BASE_URL}/${jdkVersion}.tar.gz"
  elif [ "$(expr "${jdkVersion}" : '^openjdk-')" != 0 ]; then
    local jdkUrl="${JDK_BASE_URL}/$(echo "$jdkVersion" | sed -e 's/k-/k/g').tar.gz"
  fi

  echo "${jdkUrl}"
}

get_jdk_cache_id() {
  local url="${1:?}"

  etagHeader="$(curl --head --retry 3 --silent --show-error --location "${url}" | grep ETag)"
  etag="$(echo "$etagHeader" | sed -e 's/ETag: //g' | sed -e 's/\r//g' | xargs echo)"

  if [ -n "$etag" ]; then
    echo "$etag"
  else
    echo "$(date -u)"
  fi
}

install_jdk() {
  local url="${1:?}"
  local dir="${2:?}"
  local bpDir="${3:?}"
  local key="${4:-${bpDir}/.gnupg/lang-jvm.asc}"
  local tarball="/tmp/jdk.tgz"

  curl --retry 3 --show-error --location "${url}" --output "${tarball}"

  if [ "${HEROKU_GPG_VALIDATION:-0}" != "1" ]; then
    _jvm_mcount "gpg.verify.skip"
  else
    curl --retry 3 --silent --show-error --location "${url}.gpg" --output "${tarball}.gpg"

    gpg --no-tty --batch --import "${key}" > /dev/null 2>&1

    if gpg --no-tty --batch --verify "${tarball}.gpg" "${tarball}" > /dev/null 2>&1
    then
      _jvm_mcount "gpg.verify.success"
    else
      _jvm_mcount "gpg.verify.failed"
      (>&2 echo " !     ERROR: Invalid GPG signature!")
      return 1
    fi
  fi

  tar pxzf "${tarball}" -C "${dir}"
  rm "${tarball}"
}

install_certs() {
  local jdkDir="${1:?}"
  if [ -f ${jdkDir}/jre/lib/security/cacerts ] && [ -f /etc/ssl/certs/java/cacerts ]; then
    mv ${jdkDir}/jre/lib/security/cacerts ${jdkDir}/jre/lib/security/cacerts.old
    ln -s /etc/ssl/certs/java/cacerts ${jdkDir}/jre/lib/security/cacerts
  elif [ -f ${jdkDir}/lib/security/cacerts ] && [ -f /etc/ssl/certs/java/cacerts ]; then
    mv ${jdkDir}/lib/security/cacerts ${jdkDir}/lib/security/cacerts.old
    ln -s /etc/ssl/certs/java/cacerts ${jdkDir}/lib/security/cacerts
  fi
}

install_profile() {
  local bpDir="${1:?}"
  local profileDir="${2:?}"

  mkdir -p "$profileDir"
  cp "${bpDir}/opt/jvmcommon.sh" "${profileDir}"
  cp "${bpDir}/opt/jdbc.sh" "${profileDir}"
  cp "${bpDir}/opt/jvm-redis.sh" "${profileDir}"
}

install_jdk_overlay() {
  local jdkDir="${1:?}"
  local appDir="${2:?}"
  local cacertPath="lib/security/cacerts"
  shopt -s dotglob
  if [ -d ${jdkDir} ] && [ -d ${appDir}/.jdk-overlay ]; then
    # delete the symlink because a cp will error
    if [ -f ${appDir}/.jdk-overlay/jre/${cacertPath} ] && [ -f ${jdkDir}/jre/${cacertPath} ]; then
      rm ${jdkDir}/jre/${cacertPath}
    elif [ -f ${appDir}/.jdk-overlay/${cacertPath} ] && [ -f ${jdkDir}/${cacertPath} ]; then
      rm ${jdkDir}/${cacertPath}
    fi
    cp -r ${appDir}/.jdk-overlay/* ${jdkDir}
  fi
}

install_metrics_agent() {
  local bpDir=${1:?}
  local installDir="${2:?}"
  local profileDir="${3:?}"
  local agentJar="${installDir}/heroku-metrics-agent.jar"

  mkdir -p ${installDir}
  curl --retry 3 -s -o ${agentJar} \
      -L ${HEROKU_METRICS_JAR_URL:-"https://repo1.maven.org/maven2/com/heroku/agent/heroku-java-metrics-agent/3.14/heroku-java-metrics-agent-3.14.jar"}
  if [ -f ${agentJar} ]; then
    mkdir -p ${profileDir}
    cp "${bpDir}/opt/heroku-jvm-metrics.sh" "${profileDir}"
  fi
}

install_jre() {
  local jdkDir="${1:?}"
  local jreDir="${2:?}"

  if [ -d "${jdkDir}/jre" ]; then
    rm -rf "${jreDir}"
    cp -TR "${jdkDir}/jre" "${jreDir}"
  else
    cp -TR "${jdkDir}" "${jreDir}"
  fi
}

_get_system_property() {
  local file=${1:?}
  local key=${2:?}

  # escape for regex
  local escaped_key=$(echo $key | sed "s/\./\\\./g")

  [ -f $file ] && \
  grep -E ^$escaped_key[[:space:]=]+ $file | \
  sed -E -e "s/$escaped_key([\ \t]*=[\ \t]*|[\ \t]+)([_A-Za-z0-9\.-]*).*/\2/g"
}
