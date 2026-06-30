--define:nimPreviewSlimSystem
# LOCAL WORKAROUND (do not commit): Nim's default threads:on allocator segfaults
# in this WSL2 environment during nimsem's njvl/contracts analysis. useMalloc
# sidesteps it. Remove before producing any upstream PR.
--define:useMalloc
--warningAsError:Uninit
--warningAsError:ProveInit
--experimental:strictDefs
--warning:StdPrefix
--warningAsError:StdPrefix