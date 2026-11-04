--define:nimPreviewSlimSystem
--experimental:strictDefs
when not defined(windows):
  --warningAsError:Uninit
  --warningAsError:ProveInit
--warning:StdPrefix
--warningAsError:StdPrefix