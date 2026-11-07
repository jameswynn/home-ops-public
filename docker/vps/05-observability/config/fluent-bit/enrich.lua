-- Turn a docker log file path into a container name.
--
-- The json-file driver writes to /var/lib/docker/containers/<id>/<id>-json.log and puts
-- the human name in config.v2.json next to it ("Name":"/caddy"). That file is the reason
-- this stack does not mount the docker socket: the name is the only thing we need from
-- the daemon, and it is already on disk in the read-only mount.
--
-- Cache is keyed by the full container id, which docker never reuses, so a recreated
-- container gets a fresh lookup rather than a stale name. It grows with the number of
-- distinct containers this host has ever run — a handful, since the CI runner's job
-- containers live inside the dind daemon's own storage, not here.

local names = {}

local function container_name(id)
  local cached = names[id]
  if cached then
    return cached
  end

  local f = io.open("/var/lib/docker/containers/" .. id .. "/config.v2.json", "r")
  if not f then
    return nil
  end
  local body = f:read("*a")
  f:close()

  -- Leading slash is docker's own naming convention, not part of the name.
  local name = body:match('"Name":"/?([^"]+)"')
  if name then
    names[id] = name
  end
  return name
end

function enrich(tag, timestamp, record)
  local path = record["log_path"]
  if not path then
    return 0, 0, 0
  end

  local id = path:match("/containers/([0-9a-f]+)/")
  if not id then
    return 0, 0, 0
  end

  local name = container_name(id)

  -- Drop our own output. fluent-bit's logs go to stderr, which docker writes to a file
  -- this very input is tailing; shipping them back would turn a Loki hiccup into a
  -- feedback loop that generates more error lines the worse it gets.
  if name == "fluent-bit" then
    return -1, 0, 0
  end

  record["log_path"] = nil
  record["container_id"] = id:sub(1, 12)
  record["container_name"] = name or id:sub(1, 12)

  -- 2 = record replaced, keep the original timestamp.
  return 2, timestamp, record
end
