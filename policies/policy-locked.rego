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

CreateContainerRequest {
    input.OCI.Annotations["io.kubernetes.cri.container-name"] == "model-init"
    startswith(input.OCI.Annotations["io.kubernetes.cri.image-name"], "{model_image_repo}:")
    input.OCI.Process.Args == ["/bin/cp", "-r", "/model/.", "/models-cache/"]
}

CreateContainerRequest {
    input.OCI.Annotations["io.kubernetes.cri.container-name"] == "model-init"
    startswith(input.OCI.Annotations["io.kubernetes.cri.image-name"], "{model_image_repo}@")
    input.OCI.Process.Args == ["/bin/cp", "-r", "/model/.", "/models-cache/"]
}

CreateContainerRequest {
    input.OCI.Annotations["io.kubernetes.cri.container-name"] == "app"
    startswith(input.OCI.Annotations["io.kubernetes.cri.image-name"], "{app_image_repo}:")
    input.OCI.Process.Args == ["/bin/bash", "-c", "bash /app/decrypt.sh && python /app/app.py"]
}

CreateContainerRequest {
    input.OCI.Annotations["io.kubernetes.cri.container-name"] == "app"
    startswith(input.OCI.Annotations["io.kubernetes.cri.image-name"], "{app_image_repo}@")
    input.OCI.Process.Args == ["/bin/bash", "-c", "bash /app/decrypt.sh && python /app/app.py"]
}
