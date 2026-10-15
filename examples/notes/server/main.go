// Command server serves the example notes.v1.NotesService from memory, over
// the Connect protocol (and gRPC and gRPC-Web, which connect-go serves too) at
// /notes.v1.NotesService/<Method>, and over HTTP transcoding at the paths the
// proto's google.api.http rules give, from one port: by Vanguard at the root,
// and by grpc-gateway under /gateway, which calls the service over gRPC
// (gateway.go). The behaviours the live suite relies on are documented on
// the service in notes.proto, and the routes beside it (/healthz, /status/,
// /grpc-status/) on their handlers. Beside it, routes.v1.Routes, the route
// fixtures' service, echoes each request (routes.go), and GET /routes/layers
// and GET /gateway/routes/layers say where each of its bindings is served.
// With -static, it also serves a directory's files, the browser example
// among them, from the same origin as the API.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"connectrpc.com/connect/v2"
	"connectrpc.com/connect/v2/connecthttp"
	"connectrpc.com/connect/v2/connectproto"
	"connectrpc.com/vanguard"
	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/known/anypb"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/fieldmaskpb"
	"google.golang.org/protobuf/types/known/structpb"
	"google.golang.org/protobuf/types/known/timestamppb"

	notesv1 "github.com/bruckner/elm-connect/examples/notes/server/gen/notes/v1"
	"github.com/bruckner/elm-connect/examples/notes/server/gen/notes/v1/notesv1connect"
)

const (
	slowName  = "notes/slow"
	flakyName = "notes/flaky"
	slowDelay = 2 * time.Second
	domain    = "notes.example.com"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:8080", "the address to listen on; port 0 picks a free one")
	static := flag.String("static", "", "a directory whose files to serve too, index.html at /, such as ../elm/dist")
	flag.Parse()

	listener, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatal(err)
	}
	handler, err := newHandler(newStore(), listener.Addr().String())
	if err != nil {
		log.Fatal(err)
	}
	if *static != "" {
		handler = withStatic(os.DirFS(*static), handler)
	}
	// The first line out is the address, so a script that asked for port 0
	// learns which one it got.
	fmt.Printf("listening on http://%s\n", listener.Addr())

	// HTTP/2 without TLS too, for the gateway's gRPC calls to this server.
	protocols := new(http.Protocols)
	protocols.SetHTTP1(true)
	protocols.SetUnencryptedHTTP2(true)
	server := &http.Server{Handler: handler, ReadHeaderTimeout: 10 * time.Second, Protocols: protocols}
	go func() {
		stop := make(chan os.Signal, 1)
		signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
		<-stop
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
	}()
	if err := server.Serve(listener); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

// newHandler serves the services over Connect and over transcoding, under
// Vanguard and under grpc-gateway, /healthz, and the x-echo header on every
// response. self is the server's own address, which the gateway calls.
func newHandler(svc notesv1connect.NotesServiceHandler, self string) (http.Handler, error) {
	server := connect.NewServer()
	notesv1connect.RegisterNotesServiceHandler(server, svc)

	mux := http.NewServeMux()
	routeRules, err := mountRoutes(mux, server)
	if err != nil {
		return nil, err
	}
	connecthttp.Mount(mux, server)
	// Vanguard takes "/" and serves every google.api.http rule; the Connect
	// routes above are more specific, so a method without a rule is reached
	// at its Connect path, which is the implicit route.
	if err := vanguard.Mount(mux, server, vanguard.WithRules(routeRules...)); err != nil {
		return nil, err
	}
	if err := mountGateway(mux, self); err != nil {
		return nil, err
	}
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("/status/{status}/", failWithStatus)
	mux.HandleFunc("/grpc-status/{code}/", failWithGrpcStatus)
	return echo(mux), nil
}

// failWithStatus answers any request under /status/<status>/ with that HTTP
// status and a plain-text body: an answer without an error body, as a proxy or
// a server without the route gives.
func failWithStatus(w http.ResponseWriter, r *http.Request) {
	status, err := strconv.Atoi(r.PathValue("status"))
	if err != nil || status < 200 || status > 599 {
		http.Error(w, "no such status", http.StatusBadRequest)
		return
	}
	http.Error(w, http.StatusText(status), status)
}

// failWithGrpcStatus answers any request under /grpc-status/<code>/ with HTTP
// 503 and no body, the error in grpc-status and grpc-message headers, as a
// gRPC proxy does when it has no backend to ask.
func failWithGrpcStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Grpc-Status", r.PathValue("code"))
	w.Header().Set("Grpc-Message", url.PathEscape("no backend; code "+r.PathValue("code")))
	w.WriteHeader(http.StatusServiceUnavailable)
}

// withStatic serves the files of dir to GET and HEAD requests naming one,
// index.html at /, and passes every other request to next. No API route names
// a file, so the page and the API share one origin without CORS.
func withStatic(dir fs.FS, next http.Handler) http.Handler {
	files := http.FileServerFS(dir)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet || r.Method == http.MethodHead {
			name := strings.TrimPrefix(r.URL.Path, "/")
			if name == "" {
				name = "index.html"
			}
			if info, err := fs.Stat(dir, name); err == nil && !info.IsDir() {
				files.ServeHTTP(w, r)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

// echo sends a request's x-echo header back as a response header.
func echo(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if value := r.Header.Get("X-Echo"); value != "" {
			w.Header().Set("X-Echo", value)
		}
		next.ServeHTTP(w, r)
	})
}

// store holds the notes in memory.
type store struct {
	notesv1connect.UnimplementedNotesServiceHandler

	mu    sync.Mutex
	notes map[string]*notesv1.Note
	// flakyCalls counts the calls naming notes/flaky; the odd ones fail.
	flakyCalls int
}

func newStore() *store {
	created := timestamppb.New(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC))
	attachment, err := anypb.New(timestamppb.New(time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)))
	if err != nil {
		panic(err)
	}
	extra, err := structpb.NewStruct(map[string]any{"pinned": true, "stars": 3, "owner": "ada"})
	if err != nil {
		panic(err)
	}
	s := &store{notes: map[string]*notesv1.Note{}}
	for _, note := range []*notesv1.Note{
		{
			Name:       "notes/welcome",
			Title:      "Welcome",
			Body:       "Every field of a note is set here.",
			Tags:       []string{"intro", "example"},
			Visibility: notesv1.Visibility_VISIBILITY_PUBLIC,
			CreateTime: created,
			UpdateTime: created,
			Ttl:        durationpb.New(90 * time.Second),
			Metadata:   map[string]string{"lang": "en"},
			Extra:      extra,
			Kind:       &notesv1.Note_Link{Link: "https://example.com/welcome"},
			Attachment: attachment,
			Revision:   proto.Int64(9007199254740993),
		},
		{Name: slowName, Title: "Slow", CreateTime: created, UpdateTime: created},
		{Name: flakyName, Title: "Flaky", CreateTime: created, UpdateTime: created},
	} {
		s.notes[note.Name] = note
	}
	return s
}

// before applies the behaviours every method has for the note it names.
func (s *store) before(name string) error {
	switch name {
	case slowName:
		// The whole delay, whatever the call's deadline: a client asking for
		// less must give up first.
		time.Sleep(slowDelay)
	case flakyName:
		s.mu.Lock()
		s.flakyCalls++
		fail := s.flakyCalls%2 == 1
		s.mu.Unlock()
		if fail {
			return connect.NewError(connect.CodeUnavailable, "notes/flaky is unavailable; try again")
		}
	}
	return nil
}

func (s *store) GetNote(_ context.Context, req *notesv1.GetNoteRequest) (*notesv1.Note, error) {
	if err := s.before(req.GetName()); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	note, ok := s.notes[req.GetName()]
	if !ok {
		return nil, notFound(req.GetName())
	}
	return note, nil
}

func (s *store) ListNotes(_ context.Context, req *notesv1.ListNotesRequest) (*notesv1.ListNotesResponse, error) {
	size := int(req.GetPageSize())
	if size <= 0 {
		size = 50
	}
	start := 0
	if token := req.GetPageToken(); token != "" {
		n, err := strconv.Atoi(token)
		if err != nil || n < 0 {
			return nil, connect.NewError(connect.CodeInvalidArgument, "page_token is not one this server gave")
		}
		start = n
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var matching []*notesv1.Note
	for _, note := range s.notes {
		if req.GetFilter() != "" && !strings.Contains(note.GetTitle(), req.GetFilter()) {
			continue
		}
		if req.GetVisibility() != notesv1.Visibility_VISIBILITY_UNSPECIFIED && note.GetVisibility() != req.GetVisibility() {
			continue
		}
		matching = append(matching, note)
	}
	slices.SortFunc(matching, func(a, b *notesv1.Note) int { return strings.Compare(a.GetName(), b.GetName()) })
	res := &notesv1.ListNotesResponse{}
	if start < len(matching) {
		end := min(start+size, len(matching))
		res.Notes = matching[start:end]
		if end < len(matching) {
			res.NextPageToken = strconv.Itoa(end)
		}
	}
	return res, nil
}

func (s *store) CreateNote(_ context.Context, req *notesv1.CreateNoteRequest) (*notesv1.Note, error) {
	note := proto.Clone(req.GetNote()).(*notesv1.Note)
	if note == nil {
		note = &notesv1.Note{}
	}
	if note.GetTitle() == "" {
		return nil, badRequest("title", "a note needs a title")
	}
	if note.Name == "" {
		note.Name = "notes/" + slug(note.GetTitle())
	}
	if err := s.before(note.GetName()); err != nil {
		return nil, err
	}
	now := timestamppb.Now()
	note.CreateTime = now
	note.UpdateTime = now
	note.Revision = nil
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, taken := s.notes[note.Name]; taken {
		return nil, connect.NewError(connect.CodeAlreadyExists, note.Name+" already exists")
	}
	s.notes[note.Name] = note
	return note, nil
}

func (s *store) UpdateNote(_ context.Context, req *notesv1.UpdateNoteRequest) (*notesv1.Note, error) {
	name := req.GetNote().GetName()
	if err := s.before(name); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	stored, ok := s.notes[name]
	if !ok {
		return nil, notFound(name)
	}
	updated := proto.Clone(stored).(*notesv1.Note)
	if err := apply(updated, req.GetNote(), req.GetUpdateMask()); err != nil {
		return nil, err
	}
	if updated.GetTitle() == "" {
		return nil, badRequest("title", "a note needs a title")
	}
	updated.Name = name
	updated.CreateTime = stored.GetCreateTime()
	updated.UpdateTime = timestamppb.Now()
	updated.Revision = proto.Int64(stored.GetRevision() + 1)
	s.notes[name] = updated
	return updated, nil
}

func (s *store) DeleteNote(_ context.Context, req *notesv1.DeleteNoteRequest) (*emptypb.Empty, error) {
	if err := s.before(req.GetName()); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.notes[req.GetName()]; !ok {
		return nil, notFound(req.GetName())
	}
	delete(s.notes, req.GetName())
	return &emptypb.Empty{}, nil
}

func (s *store) ArchiveNote(_ context.Context, req *notesv1.ArchiveNoteRequest) (*notesv1.Note, error) {
	if err := s.before(req.GetName()); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	stored, ok := s.notes[req.GetName()]
	if !ok {
		return nil, notFound(req.GetName())
	}
	archived := proto.Clone(stored).(*notesv1.Note)
	archived.Visibility = notesv1.Visibility_VISIBILITY_PRIVATE
	if !slices.Contains(archived.Tags, "archived") {
		archived.Tags = append(archived.Tags, "archived")
	}
	archived.UpdateTime = timestamppb.Now()
	archived.Revision = proto.Int64(stored.GetRevision() + 1)
	s.notes[req.GetName()] = archived
	return archived, nil
}

func (s *store) Ping(context.Context, *emptypb.Empty) (*emptypb.Empty, error) {
	return &emptypb.Empty{}, nil
}

// apply copies the fields of from that mask names onto to, by proto name, or
// every field from sets when the mask is empty.
func apply(to, from *notesv1.Note, mask *fieldmaskpb.FieldMask) error {
	if len(mask.GetPaths()) == 0 {
		proto.Merge(to, from)
		return nil
	}
	fields := to.ProtoReflect().Descriptor().Fields()
	for _, path := range mask.GetPaths() {
		field := fields.ByName(protoName(path))
		if field == nil {
			return badRequest("update_mask", "no field "+path)
		}
		if from.ProtoReflect().Has(field) {
			to.ProtoReflect().Set(field, from.ProtoReflect().Get(field))
		} else {
			to.ProtoReflect().Clear(field)
		}
	}
	return nil
}

func protoName(path string) protoreflect.Name { return protoreflect.Name(path) }

func notFound(name string) error {
	detail, err := connectproto.NewErrorDetail(&errdetails.ErrorInfo{
		Reason:   "NOTE_NOT_FOUND",
		Domain:   domain,
		Metadata: map[string]string{"name": name},
	})
	if err != nil {
		return err
	}
	return connect.NewError(connect.CodeNotFound, name+" does not exist").WithDetail(detail)
}

func badRequest(field, description string) error {
	detail, err := connectproto.NewErrorDetail(&errdetails.BadRequest{
		FieldViolations: []*errdetails.BadRequest_FieldViolation{{Field: field, Description: description}},
	})
	if err != nil {
		return err
	}
	return connect.NewError(connect.CodeInvalidArgument, description).WithDetail(detail)
}

// slug is a note id from a title: lowercase letters and digits, the rest as
// dashes.
func slug(title string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(title) {
		if ('a' <= r && r <= 'z') || ('0' <= r && r <= '9') {
			b.WriteRune(r)
		} else {
			b.WriteByte('-')
		}
	}
	return strings.Trim(b.String(), "-")
}
