package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/grpc-ecosystem/grpc-gateway/v2/runtime"
	"google.golang.org/genproto/googleapis/api/annotations"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	notesv1 "github.com/bruckner/elm-connect/examples/notes/server/gen/notes/v1"
	routesv1 "github.com/bruckner/elm-connect/examples/notes/server/gen/routes/v1"
	routesapart "github.com/bruckner/elm-connect/examples/notes/server/gen/routes/v1/apart"
)

// gatewayPrefix is where grpc-gateway serves notes.v1 and routes.v1: a
// client's base URL is http://host/gateway, and the prefix is stripped
// before the gateway's mux sees the path, so the rules' paths are served
// as written beneath it.
const gatewayPrefix = "/gateway"

// mountGateway serves notes.v1 and routes.v1 under grpc-gateway at
// /gateway/, as a gateway deployed in front of a gRPC service does: each
// call is proxied over gRPC to target, this server's own address, where
// connect-go answers it. A service error reaches the gateway as a gRPC
// status with its details, and the gateway writes it as a
// google.rpc.Status body.
//
// protoc-gen-grpc-gateway will not generate UpdateMessageWhole beside
// UpdateMessage (buf.gen.gateway.yaml), so it is served by a second
// gateway mux under /gateway/layer/1, as Vanguard's refused bindings are
// under /layer/1. GET /gateway/routes/layers lists where each routes.v1
// binding is served, relative to /gateway.
func mountGateway(mux *http.ServeMux, target string) error {
	conn, err := grpc.NewClient(target, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return err
	}
	ctx := context.Background()
	gateway := runtime.NewServeMux()
	if err := notesv1.RegisterNotesServiceHandler(ctx, gateway, conn); err != nil {
		return err
	}
	if err := routesv1.RegisterRoutesHandler(ctx, gateway, conn); err != nil {
		return err
	}
	mux.Handle(gatewayPrefix+"/", http.StripPrefix(gatewayPrefix, gateway))

	apart := runtime.NewServeMux()
	if err := routesapart.RegisterRoutesHandler(ctx, apart, conn); err != nil {
		return err
	}
	mux.Handle(gatewayPrefix+"/layer/1/", http.StripPrefix(gatewayPrefix+"/layer/1", apart))

	listing, err := json.Marshal(gatewayLayers())
	if err != nil {
		return err
	}
	mux.HandleFunc("GET "+gatewayPrefix+"/routes/layers", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(listing)
	})
	return nil
}

// gatewayLayers places every routes.v1 binding as the gateway serves it.
// protoc-gen-grpc-gateway refuses a binding whose verb and path template a
// binding before it in the service has; a method with such a binding is
// generated apart (buf.gen.gateway-apart.yaml) and served under
// /layer/1. Bindings that differ in template but match the same paths are
// both generated, and the mux tries the one registered last first.
func gatewayLayers() []routeBinding {
	bindings := routeBindings()
	first := map[string]routeBinding{}
	apart := map[string]string{}
	for _, b := range bindings {
		verb, path := verbAndPath(b.rule)
		key := verb + " " + path
		if earlier, ok := first[key]; ok {
			if _, done := apart[b.Method]; !done {
				apart[b.Method] = fmt.Sprintf("%s is %s binding %d's too; protoc-gen-grpc-gateway refuses a second binding of a verb and path template in one service (\"duplicate annotation: method=%s, template=%s\").", key, earlier.Method, earlier.Binding, verb, path)
			}
			continue
		}
		first[key] = b
	}
	for i := range bindings {
		if reason, ok := apart[bindings[i].Method]; ok {
			bindings[i].Layer = 1
			bindings[i].Prefix = "/layer/1"
			bindings[i].Reason = reason
		}
	}
	return bindings
}

// verbAndPath is a rule's verb and path template, as the generator compares
// them.
func verbAndPath(rule *annotations.HttpRule) (string, string) {
	switch p := rule.GetPattern().(type) {
	case *annotations.HttpRule_Get:
		return "GET", p.Get
	case *annotations.HttpRule_Put:
		return "PUT", p.Put
	case *annotations.HttpRule_Post:
		return "POST", p.Post
	case *annotations.HttpRule_Delete:
		return "DELETE", p.Delete
	case *annotations.HttpRule_Patch:
		return "PATCH", p.Patch
	case *annotations.HttpRule_Custom:
		return p.Custom.GetKind(), p.Custom.GetPath()
	}
	return "", ""
}
