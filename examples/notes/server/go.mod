module github.com/bruckner/elm-connect/examples/notes/server

go 1.27.2

tool (
	connectrpc.com/connect/v2/cmd/protoc-gen-connect-go
	google.golang.org/protobuf/cmd/protoc-gen-go
)

require (
	connectrpc.com/connect/v2 v2.0.1
	connectrpc.com/vanguard v0.5.0
	google.golang.org/genproto/googleapis/api v0.0.0-20260526163538-3dc84a4a5aaa
	google.golang.org/genproto/googleapis/rpc v0.0.0-20261012220534-4341edf3f941
	google.golang.org/protobuf v1.36.12
)
