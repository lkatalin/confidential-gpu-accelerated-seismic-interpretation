package agent_policy
import future.keywords.in
import future.keywords.if
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
    input.OCI.Annotations["io.kubernetes.container.name"] == "model-init"
    input.OCI.Process.Args == ["/bin/cp", "-r", "/model/.", "/models-cache/"]
    some storage in input.storages
    startswith(storage.source, "{model_image_repo}:")
}

CreateContainerRequest if {
    input.OCI.Annotations["io.kubernetes.container.name"] == "model-init"
    input.OCI.Process.Args == ["/bin/cp", "-r", "/model/.", "/models-cache/"]
    some storage in input.storages
    startswith(storage.source, "{model_image_repo}@")
}

CreateContainerRequest if {
    input.OCI.Annotations["io.kubernetes.container.name"] == "app"
    input.OCI.Process.Args == ["/bin/bash", "-c", "bash /app/decrypt.sh && python /app/app.py"]
    some storage in input.storages
    startswith(storage.source, "{app_image_repo}:")
}

CreateContainerRequest if {
    input.OCI.Annotations["io.kubernetes.container.name"] == "app"
    input.OCI.Process.Args == ["/bin/bash", "-c", "bash /app/decrypt.sh && python /app/app.py"]
    some storage in input.storages
    startswith(storage.source, "{app_image_repo}@")
}
