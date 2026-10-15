package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"

	"connectrpc.com/connect/v2"
	"connectrpc.com/vanguard"
	"google.golang.org/genproto/googleapis/api/annotations"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/dynamicpb"

	routesv1 "github.com/bruckner/elm-connect/examples/notes/server/gen/routes/v1"
)

// routes.v1.Routes is the route fixtures' service
// (conformance/routes/routes.proto). Every method echoes its request as the
// transcoder decoded it, so the live suite can compare what the server
// understood with what the client meant: a method whose response is its
// request type returns the request, the others the request as proto3 JSON
// (protojson's canonical form) in one string field of the response,
// echoField's.
var echoField = map[protoreflect.FullName]protoreflect.Name{
	"routes.v1.Message":  "text",
	"routes.v1.Resource": "display_name",
}

// routeBinding is one binding of a routes.v1 method: its rule, and the
// layer of the server that serves it.
type routeBinding struct {
	Method  string `json:"method"`
	Binding int    `json:"binding"`
	Layer   int    `json:"layer"`
	Prefix  string `json:"prefix"`
	// Why the binding is not on the first layer: Vanguard's error when it
	// was tried there.
	Reason string `json:"reason,omitempty"`
	rule   *annotations.HttpRule
}

// routeLayers places every binding. The fixtures' rules overlap: GetMessage's first and third bindings are
// both GET /v1/messages/*, and UpdateMessage and UpdateMessageWhole are both
// PATCH /v1/messages/{message_id}. Vanguard refuses a second route for a
// verb and path it already has, so the bindings are served in layers: each
// binding goes on the first layer that takes it, the first layer at the
// root beside notes.v1, layer n under /layer/<n>, the prefix stripped
// before Vanguard sees the path. GET /routes/layers lists every binding
// and where it is served.
func routeLayers() []routeBinding {
	var bindings []routeBinding
	methods := routesv1.File_routes_proto.Services().ByName("Routes").Methods()
	for i := range methods.Len() {
		method := methods.Get(i)
		rule, ok := proto.GetExtension(method.Options(), annotations.E_Http).(*annotations.HttpRule)
		if !ok || rule == nil || rule.GetPattern() == nil {
			continue
		}
		first := proto.Clone(rule).(*annotations.HttpRule)
		first.AdditionalBindings = nil
		for n, r := range append([]*annotations.HttpRule{first}, rule.GetAdditionalBindings()...) {
			r = proto.Clone(r).(*annotations.HttpRule)
			r.Selector = string(method.FullName())
			bindings = append(bindings, routeBinding{Method: string(method.FullName()), Binding: n, rule: r})
		}
	}
	var layers [][]*annotations.HttpRule
	for i := range bindings {
		b := &bindings[i]
		for layer := 0; ; layer++ {
			if layer == len(layers) {
				layers = append(layers, nil)
			}
			candidate := append(append([]*annotations.HttpRule{}, layers[layer]...), b.rule)
			err := vanguard.Mount(http.NewServeMux(), newRoutesServer(), vanguard.WithRules(candidate...))
			if err == nil {
				layers[layer] = candidate
				b.Layer = layer
				if layer > 0 {
					b.Prefix = fmt.Sprintf("/layer/%d", layer)
				}
				break
			}
			if b.Reason == "" {
				b.Reason = err.Error()
			}
		}
	}
	return bindings
}

// mountRoutes registers routes.v1 on the root server, and serves the
// bindings of its first layer with the root's Vanguard (the rules returned)
// and those of the other layers under /layer/<n>.
func mountRoutes(mux *http.ServeMux, root *connect.Server) ([]*annotations.HttpRule, error) {
	registerRoutes(root)
	bindings := routeLayers()
	rules := map[int][]*annotations.HttpRule{}
	for _, b := range bindings {
		rules[b.Layer] = append(rules[b.Layer], b.rule)
		if b.Reason != "" {
			log.Printf("routes.v1: %s binding %d served under %s: %s", b.Method, b.Binding, b.Prefix, b.Reason)
		}
	}
	for layer := 1; layer < len(rules); layer++ {
		sub := http.NewServeMux()
		if err := vanguard.Mount(sub, newRoutesServer(), vanguard.WithRules(rules[layer]...)); err != nil {
			return nil, err
		}
		prefix := fmt.Sprintf("/layer/%d", layer)
		mux.Handle(prefix+"/", http.StripPrefix(prefix, sub))
	}
	listing, err := json.Marshal(bindings)
	if err != nil {
		return nil, err
	}
	mux.HandleFunc("GET /routes/layers", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(listing)
	})
	return rules[0], nil
}

func newRoutesServer() *connect.Server {
	server := connect.NewServer()
	registerRoutes(server)
	return server
}

// unannotated is routes.proto without its google.api.http options, so that
// Vanguard takes the rules from WithRules alone. Its messages are not the
// generated ones, so the handlers use dynamic messages of its types, and so
// does Vanguard.
var unannotated = func() protoreflect.FileDescriptor {
	file := protodesc.ToFileDescriptorProto(routesv1.File_routes_proto)
	for _, service := range file.GetService() {
		for _, method := range service.GetMethod() {
			if method.GetOptions() != nil {
				proto.ClearExtension(method.GetOptions(), annotations.E_Http)
			}
		}
	}
	stripped, err := protodesc.NewFile(file, protoregistry.GlobalFiles)
	if err != nil {
		panic(err)
	}
	return stripped
}()

// registerRoutes registers every routes.v1.Routes method on server, echoing.
func registerRoutes(server *connect.Server) {
	methods := unannotated.Services().ByName("Routes").Methods()
	for i := range methods.Len() {
		method := methods.Get(i)
		server.Register(connect.Method{
			Spec: connect.Spec{
				StreamType: connect.StreamTypeUnary,
				Schema:     method,
				Procedure:  fmt.Sprintf("/%s/%s", method.Parent().FullName(), method.Name()),
			},
			Handler: func(_ context.Context, _ connect.Spec, stream connect.ServerStream) error {
				req := dynamicpb.NewMessage(method.Input())
				if err := stream.Receive(req); err != nil {
					return err
				}
				res, err := echoOf(req, method.Output())
				if err != nil {
					return err
				}
				return stream.Send(res)
			},
		})
	}
}

// echoOf is the response of type output to req: req itself if it is one,
// otherwise req as proto3 JSON in the response's echoField.
func echoOf(req *dynamicpb.Message, output protoreflect.MessageDescriptor) (proto.Message, error) {
	if req.Descriptor().FullName() == output.FullName() {
		return req, nil
	}
	text, err := protojson.Marshal(req)
	if err != nil {
		return nil, err
	}
	field := output.Fields().ByName(echoField[output.FullName()])
	if field == nil {
		return nil, connect.NewError(connect.CodeInternal, "no echo field in "+string(output.FullName()))
	}
	res := dynamicpb.NewMessage(output)
	res.Set(field, protoreflect.ValueOfString(string(text)))
	return res, nil
}
