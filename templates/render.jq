# Fill a static text template with typed JSON. Credentials are escaped by jq.
. as $state |
($state.whitelist | length > 0) as $limited |
({type:"field", inboundTag:["socks-in"]} +
    if $limited then {source:$state.whitelist} else {} end) as $allowed |
$template[0] |
.inbounds[0].listen = $state.listen |
.inbounds[0].port = $state.port |
.inbounds[0].settings.accounts = [{user:$state.username, pass:$state.password}] |
.outbounds += (if $state.upstream == null then [] else [{
  tag:"upstream", protocol:"socks", settings:{servers:[{
    address:$state.upstream.host, port:$state.upstream.port,
    users:[{user:$state.upstream.username, pass:$state.upstream.password}]
  }]}
}] end) |
.routing.rules = (
  (if $state.mode == "domain" then
     [$allowed + {domain:$state.domains, outboundTag:"upstream"}]
   else [] end) +
  [$allowed + {outboundTag:(if $state.mode == "global" then "upstream" else "direct" end)}] +
  (if $limited then [{type:"field", inboundTag:["socks-in"], outboundTag:"blocked"}] else [] end)
) |
.outbounds += (if $limited then [{tag:"blocked", protocol:"blackhole", settings:{}}] else [] end)
