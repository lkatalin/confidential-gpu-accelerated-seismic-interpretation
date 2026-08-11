package agent_policy
import future.keywords.in
import future.keywords.if
import future.keywords.every
default AddARPNeighborsRequest := true
default AddSwapRequest := true
default CloseStdinRequest := true
default CopyFileRequest := false
default CreateContainerRequest := false
default CreateSandboxRequest := true
default DestroySandboxRequest := true
default GetDiagnosticDataRequest := false
default GetMetricsRequest := true
default GetOOMEventRequest := true
default GuestDetailsRequest := true
default ListInterfacesRequest := true
default ListRoutesRequest := true
default MemHotplugByProbeRequest := true
default OnlineCPUMemRequest := true
default PauseContainerRequest := true
default PullImageRequest := true
default ReadStreamRequest := true
default RemoveContainerRequest := true
default RemoveStaleVirtiofsShareMountsRequest := true
default ReseedRandomDevRequest := true
default ResumeContainerRequest := true
default SetGuestDateTimeRequest := true
default SetPolicyRequest := false
default SignalProcessRequest := true
default StartContainerRequest := true
default StartTracingRequest := false
default StatsContainerRequest := true
default StopTracingRequest := false
default TtyWinResizeRequest := false
default UpdateContainerRequest := true
default UpdateEphemeralMountsRequest := true
default UpdateInterfaceRequest := true
default UpdateRoutesRequest := true
default WaitProcessRequest := true
default WriteStreamRequest := false
default ExecProcessRequest := false

# Rule 1: Allow exact system networking files
CopyFileRequest if {
    allowed_system_paths := {
        "/etc/resolv.conf",
        "/etc/hosts",
        "/etc/hostname"
    }
    allowed_system_paths[input.path]
}

# Rule 2: Allow Kubernetes mounted volumes (ConfigMaps, Secrets, Tokens)
# Kata Containers stages host-side volume mounts inside this shared guest directory:
CopyFileRequest if {
    startswith(input.path, "/run/kata-containers/shared/containers/")
}

CreateContainerRequest if {
    some container in policy_data.containers
    input.OCI.Process.Args == container.OCI.Process.Args
    count(input.storages) > 0
    every storage in input.storages {
        storage_allowed(storage, container)
    }
}

storage_allowed(storage, container) if {
    storage.driver == "image_guest_pull"
    some allowed_storage in container.storages
    startswith(storage.source, allowed_storage.source)
}

storage_allowed(storage, container) if {
    storage.driver == "ephemeral"
    some allowed_storage in container.storages
    storage.source == allowed_storage.source
}

policy_data := {
    "containers": [
        {
            "OCI": {
                "Process": {
                    "Args": ["/usr/bin/pod"]
                }
            },
            "storages": [
                {"source": "pause"}
            ]
        },
        {
            "OCI": {
                "Process": {
                    "Args": ["/bin/cp", "-r", "/model/.", "/models-cache/"]
                }
            },
            "storages": [
                {"source": "{model_image_repo}:"},
                {"source": "{model_image_repo}@"},
                {"source": "tmpfs"}
            ]
        },
        {
            "OCI": {
                "Process": {
                    "Args": ["/bin/bash", "-c", "bash /app/decrypt.sh && python /app/app.py"]
                }
            },
            "storages": [
                {"source": "{app_image_repo}:"},
                {"source": "{app_image_repo}@"},
                {"source": "tmpfs"}
            ]
        }
    ]
}
