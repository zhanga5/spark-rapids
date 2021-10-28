#!/bin/bash
#
# Copyright (c) 2020-2021, NVIDIA CORPORATION. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -ex

BUILD_TYPE=all

if [[ $# -eq 1 ]]; then
    BUILD_TYPE=$1

elif [[ $# -gt 1 ]]; then
    echo "ERROR: too many parameters are provided"
    exit 1
fi

BUILD_PARALLEL=${BUILD_PARALLEL:-4}

export MVN_BASE_DIR=$(mvn help:evaluate -Dexpression=project.basedir -q -DforceStdout)

build_single_shim() {
  set -x
  BUILD_VER=$1

  if [[ "$BUILD_VER" == "311" || "$BUILD_VER" == "320" ]]; then
    # Run unit test
    EXTRA_ARGS=-Dpytest.TEST_TAGS=''
  else
    EXTRA_ARGS='-DskipTests -pl aggregator -am'
  fi

  mkdir -p "$MVN_BASE_DIR/target"
  LOG_FILE="$MVN_BASE_DIR/target/mvn-build-$BUILD_VER.log"

  echo "### Begin to build_single_shim($BUILD_VER) ###" > $LOG_FILE

  env -u SPARK_HOME mvn -e -U -B $MVN_URM_MIRROR install \
      -Dbuildver="$BUILD_VER" \
      -Drat.skip=true \
      -Dmaven.javadoc.skip=true \
      -Dskip \
      -Dmaven.scalastyle.skip=true \
      -Dcuda.version=$CUDA_CLASSIFIER \
      $EXTRA_ARGS > "$LOG_FILE" 2>&1 || {
        echo "### Failed to build_single_shim($BUILD_VER) ###" >> $LOG_FILE
        cat $LOG_FILE
        exit 255
      }

  echo "### Endof of build_single_shim($BUILD_VER) ###" >> $LOG_FILE
}

export -f build_single_shim

mvn_verify() {
    echo "Run mvn verify..."
    # get merge BASE from merged pull request. Log message e.g. "Merge HEAD into BASE"
    BASE_REF=$(git --no-pager log --oneline -1 | awk '{ print $NF }')
    # file size check for pull request. The size of a committed file should be less than 1.5MiB
    pre-commit run check-added-large-files --from-ref $BASE_REF --to-ref HEAD

    # Install mvn plugin for parallel build testing: takari-local-repository
    wget -q https://github.com/takari/takari-local-repository/archive/refs/tags/takari-local-repository-0.10.4.tar.gz
    tar xf takari-local-repository-0.10.4.tar.gz
    cd takari-local-repository-takari-local-repository-0.10.4/ && mvn install
    cp ~/.m2/repository/io/takari/aether/takari-local-repository/0.10.4/takari-local-repository-0.10.4.jar /usr/share/maven/lib/
    cp ~/.m2/repository/io/takari/takari-filemanager/0.8.2/takari-filemanager-0.8.2.jar /usr/share/maven/lib/

    echo "Clean once across all modules"
    mvn -q clean

    # build all the versions in parallel but only run unit tests on one 3.0.X version (base version covers this), one 3.1.X version, and one 3.2.X version.
    # All others shims test should be covered in nightly pipelines
    SPARK_SHIM_VERSIONS=(302 303 304 311 311cdh 312 313 320)
    printf "%s\n" "${SPARK_SHIM_VERSIONS[@]}" | xargs -t -I% -n1 -P "$BUILD_PARALLEL" bash -c 'build_single_shim %'

    # Dump build logs
    cat $MVN_BASE_DIR/target/mvn-build-*.log

    # Here run Python integration tests tagged with 'premerge_ci_1' only, that would help balance test duration and memory
    # consumption from two k8s pods running in parallel, which executes 'mvn_verify()' and 'ci_2()' respectively.
    mvn -B $MVN_URM_MIRROR '-Psnapshots,pre-merge' clean verify -Dpytest.TEST_TAGS="premerge_ci_1" \
        -Dpytest.TEST_TYPE="pre-commit" -Dpytest.TEST_PARALLEL=4 -Dcuda.version=$CUDA_CLASSIFIER

    # Triggering here until we change the jenkins file
    rapids_shuffle_smoke_test
}

rapids_shuffle_smoke_test() {
    echo "Run rapids_shuffle_smoke_test..."

    # basic ucx check
    ucx_info -d

    # run in standalone mode
    export SPARK_MASTER_HOST=localhost
    export SPARK_MASTER=spark://$SPARK_MASTER_HOST:7077
    $SPARK_HOME/sbin/start-master.sh -h $SPARK_MASTER_HOST
    $SPARK_HOME/sbin/spark-daemon.sh start org.apache.spark.deploy.worker.Worker 1 $SPARK_MASTER

    PYSP_TEST_spark_master=$SPARK_MASTER \
      TEST_PARALLEL=0 \
      PYSP_TEST_spark_cores_max=2 \
      PYSP_TEST_spark_executor_cores=1 \
      SPARK_SUBMIT_FLAGS="--conf spark.executorEnv.UCX_ERROR_SIGNALS=" \
      PYSP_TEST_spark_shuffle_manager=com.nvidia.spark.rapids.$SHUFFLE_SPARK_SHIM.RapidsShuffleManager \
      PYSP_TEST_spark_rapids_memory_gpu_minAllocFraction=0 \
      PYSP_TEST_spark_rapids_memory_gpu_maxAllocFraction=0.1 \
      PYSP_TEST_spark_rapids_memory_gpu_allocFraction=0.1 \
      ./integration_tests/run_pyspark_from_build.sh -m shuffle_test

    $SPARK_HOME/sbin/spark-daemon.sh stop org.apache.spark.deploy.worker.Worker 1
    $SPARK_HOME/sbin/stop-master.sh
}

ci_2() {
    echo "Run premerge ci 2 testings..."
    mvn -U -B $MVN_URM_MIRROR clean package -DskipTests=true -Dcuda.version=$CUDA_CLASSIFIER
    export TEST_TAGS="not premerge_ci_1"
    export TEST_TYPE="pre-commit"
    export TEST_PARALLEL=4
    # separate process to avoid OOM kill
    TEST='conditionals_test or window_function_test' ./integration_tests/run_pyspark_from_build.sh
    TEST_PARALLEL=5 TEST='struct_test or time_window_test' ./integration_tests/run_pyspark_from_build.sh
    TEST='not conditionals_test and not window_function_test and not struct_test and not time_window_test' \
      ./integration_tests/run_pyspark_from_build.sh
}


nvidia-smi

. jenkins/version-def.sh

ARTF_ROOT="$WORKSPACE/.download"
MVN_GET_CMD="mvn org.apache.maven.plugins:maven-dependency-plugin:2.8:get -B \
    $MVN_URM_MIRROR -DremoteRepositories=$URM_URL \
    -Ddest=$ARTF_ROOT"

rm -rf $ARTF_ROOT && mkdir -p $ARTF_ROOT

# If possible create '~/.m2' cache from pre-created m2 tarball to minimize the impact of unstable network connection.
# Please refer to job 'update_premerge_m2_cache' on Blossom about building m2 tarball details.
M2_CACHE_TAR=${M2_CACHE_TAR:-"/home/jenkins/agent/m2_cache/premerge_m2_cache.tar"}
if [ -s "$M2_CACHE_TAR" ] ; then
    tar xf $M2_CACHE_TAR -C ~/
fi

# Download a full version of spark
$MVN_GET_CMD \
    -DgroupId=org.apache -DartifactId=spark -Dversion=$SPARK_VER -Dclassifier=bin-hadoop3.2 -Dpackaging=tgz

export SPARK_HOME="$ARTF_ROOT/spark-$SPARK_VER-bin-hadoop3.2"
export PATH="$SPARK_HOME/bin:$SPARK_HOME/sbin:$PATH"
tar zxf $SPARK_HOME.tgz -C $ARTF_ROOT && \
    rm -f $SPARK_HOME.tgz

case $BUILD_TYPE in

    all)
        echo "Run all testings..."
        mvn_verify
        ci_2
        ;;

    mvn_verify)
        mvn_verify
        ;;

    ci_2 )
        ci_2
        ;;

    *)
        echo "ERROR: unknown parameter: $BUILD_TYPE"
        ;;
esac
