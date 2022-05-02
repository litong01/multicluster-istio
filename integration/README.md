# Integration test setup

1. The command to start the test

go test -p 1 -v -count=1 -tags=integ -vet=off -timeout 30m \
  ./tests/integration/pilot/... \
  --istio.test.skipVM --istio.test.ci \
  --istio.test.pullpolicy=IfNotPresent \
  --istio.test.work_dir=/tmp/work \
  --istio.test.hub=istio --istio.test.tag=1.15-dev \
  --istio.test.kube.topology=/tmp/work/topology.json \
  "--istio.test.select=,-postsubmit"

1. If use VSCode to debug, then in the debug settings of VSCode, add a named debug setting like the following:

        {
            "name": "Launch integration tset",
            "type": "go",
            "request": "launch",
            "mode": "test",
            "buildFlags": "-tags=integ",
            "program": "${fileDirname}",
            "args": [
                "-test.run", "TestMain", "-test.v",
                "--istio.test.skipVM", "--istio.test.ci",
                "--istio.test.pullpolicy", "IfNotPresent",
                "--istio.test.work_dir", "/tmp/work",
                "--istio.test.hub", "istio", "--istio.test.tag", "1.15-dev",
                "--istio.test.kube.topology", "/tmp/work/topology.json",
                "--istio.test.kube.config", "/tmp/work/config,/tmp/work/remote,/tmp/work/external"
            ]
        }

   Notice that you have to setup buildFlags so that the go build can build integration
   test code, otherwise, the test code commented like the following wont work:

     //go:build integ
     // +build integ

   Also make sure that the second parameter in the args section matches the starting method
   that you like to test and make sure that the file is the file you are seeing when you
   click on the start debug button at the top left. Use the args to specify any other
   needed parameters.

1. Use the VS code global settings should also work so that you can use codelens for debugging. Here is an example, how to set it up (But currently it is broken)


    "go.buildTags": "integ",
    "go.testFlags":["-args", "-p=1", "-v", "-count=1", "-timeout=60m",
      "-vet=off", "--istio.test.skipVM", "--istio.test.ci",
      "--istio.test.pullpolicy=IfNotPresent",
      "--istio.test.work_dir=/tmp/work",
      "--istio.test.hub=istio", "--istio.test.tag=1.15-dev",
      "--istio.test.kube.topology=/tmp/work/topology.json"]
