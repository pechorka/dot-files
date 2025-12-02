function cdtemp
  cd "$(mktemp -d)"
end

function cdtempgo
  cd "$(mktemp -d)"
  go mod init playground
end
