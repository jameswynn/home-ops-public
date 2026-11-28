# Longhorn

## Expanding a Volume

* Scale down whatever workloads it has
* Edit PVC directly and change the capacity
* Wait for Longhorn to finish resizing it
* Update the PVC's related yaml configs to match the new capacity
* Commit
* Scale up the workloads if Flux doesn't do it automatically

## Moving a Volume

* Scale down any related workloads
* Export the PVC

  ```sh
  kubectl get pvc -n namespace pvcname -o yaml > pvc.yaml
  ```

* Edit the name and namespace to whatever it needs to be. Strip out all the other cruft.
* Apply the new yaml. This will produce a new PVC in "Pending" state.
* Copy the PVC's `metadata.uid`
* Find the PV matching the `spec.volumeName` and change it's `spec.claimRef.uid` to match the new PVC's
* Wait for the new PVC's status to change to "Bound"
* Configure workloads for the new PVC name/namespace
* Delete the old PVC
