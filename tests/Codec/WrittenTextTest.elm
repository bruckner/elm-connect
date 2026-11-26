module Codec.WrittenTextTest exposing (suite)

{-| The JSON text the generated encoders write, character for character, for
the samples of the messages whose encoders are built from runs of fields that
can be refused and fields that cannot (`Choice`, `WellKnown`, `Everything`),
under the default options. The expectations are the text the encoders wrote
before they could refuse a value, when every field was plain code: fields in
declaration order, then each oneof's member. `Codec.RoundTripTest` compares
JSON by value; this holds the order too.
-}

import Dict
import Expect
import Generated.Codec.Codecs
import Generated.Codec.Data
import Json.Encode
import Test exposing (Test, describe, test)


suite : Test
suite =
    let
        samples =
            Dict.fromList (List.map (\sample -> ( sample.name, sample )) Generated.Codec.Data.samples)

        codecs =
            Dict.fromList Generated.Codec.Codecs.default
    in
    describe "the text the generated encoders write keeps the field order"
        (List.map
            (\( name, text ) ->
                test name <|
                    \_ ->
                        case Dict.get name samples |> Maybe.andThen (\sample -> Dict.get sample.message codecs |> Maybe.map (\run -> run sample.canonical)) of
                            Just written ->
                                written
                                    |> Result.map (Json.Encode.encode 0)
                                    |> Expect.equal (Ok text)

                            Nothing ->
                                Expect.fail ("no sample or codec for " ++ name)
            )
            expected
        )


expected : List ( String, String )
expected =
    [ ( "codec.v1.Choice #0", "{}" )
    , ( "codec.v1.Choice #1", "{\"after\":-1,\"kind\":\"KIND_UNSPECIFIED\"}" )
    , ( "codec.v1.Choice #2", "{\"before\":\"_\",\"after\":-649,\"flag\":false}" )
    , ( "codec.v1.Choice #3", "{\"after\":-609826139,\"kind\":\"KIND_TEXT\"}" )
    , ( "codec.v1.Choice #4", "{\"before\":\"&AA\",\"big\":\"-7814322006959660692\"}" )
    , ( "codec.v1.Choice #5", "{\"before\":\"=+<\\u0000;\",\"after\":-2147483648,\"leaf\":{\"count\":-985}}" )
    , ( "codec.v1.Choice #6", "{\"before\":\"😀=\\b;]\\tZ%\",\"nothing\":{}}" )
    , ( "codec.v1.Choice #7", "{\"before\":\">\",\"after\":-2147483648,\"kind\":\"KIND_UNSPECIFIED\"}" )
    , ( "codec.v1.Choice text", "{\"before\":\",&$%-: ?\",\"text\":\"\"}" )
    , ( "codec.v1.Choice big", "{\"before\":\"ΩΩ\\\"\\r*\",\"big\":\"-9007199254740993\"}" )
    , ( "codec.v1.Choice ratio", "{\"before\":\"Ω>[\u{007F}A\",\"after\":-1,\"ratio\":-4.889158809881636e-48}" )
    , ( "codec.v1.Choice flag", "{\"before\":\":\u{2028}.\\u001f😀\\b\\u0000Ω\",\"after\":-2007031747,\"flag\":false}" )
    , ( "codec.v1.Choice data", "{\"after\":-65232627,\"data\":\"+U9QXA==\"}" )
    , ( "codec.v1.Choice kind", "{\"after\":-1681993001,\"kind\":\"KIND_TEXT\"}" )
    , ( "codec.v1.Choice leaf", "{\"leaf\":{\"name\":\"\\\\&&\\\\*\"}}" )
    , ( "codec.v1.Choice nothing", "{\"after\":1,\"nothing\":{}}" )
    , ( "codec.v1.Choice json", "{\"after\":-2147483648,\"json\":{\":\\u001f\":false,\":!_#@\":true}}" )
    , ( "codec.v1.Choice at", "{\"before\":\".\",\"after\":2147483647,\"at\":\"0001-01-01T00:00:00.262Z\"}" )
    , ( "codec.v1.Choice wrapped", "{\"wrapped\":-1}" )
    , ( "codec.v1.Choice two_words", "{\"twoWords\":\"\\\\\\\\!]\\u001f\"}" )
    , ( "codec.v1.Choice none", "{\"after\":648,\"none\":null}" )
    , ( "codec.v1.WellKnown #0", "{\"any\":{\"@type\":\"type.googleapis.com/codec.v1.Outer\"},\"list\":[],\"timestamp\":\"1970-01-01T00:00:00Z\",\"duration\":\"0s\",\"empty\":{},\"values\":[null],\"valueMap\":{\"-*ß# [<\\f\":false},\"timestamps\":[\"9999-12-31T23:59:59.844Z\",\"0001-01-01T00:00:00Z\"],\"empties\":[{},{}],\"nullValues\":[null,null],\"nullMap\":{\"([ *😀_@,\":null,\"~]?=<\":null}}" )
    , ( "codec.v1.WellKnown #1", "{\"any\":{\"@type\":\"type.googleapis.com/codec.v1.WellKnown\",\"empty\":{}},\"struct\":{},\"list\":[],\"timestamp\":\"1970-01-01T00:00:00Z\",\"duration\":\"0s\",\"mask\":\"ymJl6.ic5L\",\"empty\":{},\"anys\":[{\"@type\":\"type.googleapis.com/codec.v1.Wrappers\"}],\"values\":[105.375,\"  \\b</\"],\"valueMap\":{\"中\":\"][*\"},\"timestamps\":[\"9999-12-31T23:59:59.638343871Z\"],\"durations\":[\"199653531258.194495426s\"],\"structs\":{\"-758\":{\",a \":{}}},\"nullValues\":[null,null]}" )
    , ( "codec.v1.WellKnown #2", "{\"any\":{\"@type\":\"type.googleapis.com/codec.v1.Repeated\"},\"struct\":{},\"list\":[null,true],\"value\":null,\"timestamp\":\"9999-12-31T23:59:59Z\",\"duration\":\"1.101400060s\",\"empty\":{},\"anys\":[{\"@type\":\"type.googleapis.com/google.protobuf.Int64Value\",\"value\":\"0\"},{\"@type\":\"type.googleapis.com/codec.v1.Repeated\"}],\"values\":[[false,[1.1653347948273199e-294]],[]],\"valueMap\":{\"\\nßA\\n.]]😀\":null},\"timestamps\":[\"1970-01-01T00:00:00.647303Z\",\"0001-01-01T00:00:00Z\"],\"durations\":[\"0s\"],\"structs\":{\"-1010893976\":{\"%)\":{\"@\\b+0::;_\":null},\"Zé中!a-+é\":2.2250738585072014e-308},\"-255308160\":{\"[?_;𐍈\":-68.25}},\"nullValues\":[null],\"nullMap\":{\"'a\":null}}" )
    , ( "codec.v1.WellKnown #3", "{\"any\":{\"@type\":\"type.googleapis.com/google.protobuf.Int64Value\",\"value\":\"9007199254740991\"},\"struct\":{\"\u{007F}<\":5.465067054464417e+71,\"ß'[\":35.25},\"list\":[],\"timestamp\":\"1970-01-01T00:00:00.880006Z\",\"empty\":{},\"anys\":[{\"@type\":\"type.googleapis.com/codec.v1.Optionals\"}],\"values\":[[],null],\"valueMap\":{\"\\b(=zA✓A@\":{\".%Z𐍈/\":{\"_~&*[]ßA\":null}},\"𐍈\\\"✓\\f,\":[true]},\"empties\":[{},{}],\"structs\":{\"1\":{\"\\b😀 \":false,\"Ω/:\u{007F}\\u0000#\\u0001/\":false},\"-1963470116\":{\"\":null,\"𐍈#?\u{2028}&:*)\":\"Z\"}}}" )
    , ( "codec.v1.WellKnown #4", "{\"any\":{\"@type\":\"type.googleapis.com/codec.v1.Outer\"},\"struct\":{},\"list\":[],\"duration\":\"0s\",\"mask\":\"\",\"empty\":{},\"anys\":[{\"@type\":\"type.googleapis.com/codec.v1.WellKnown\",\"empty\":{}}],\"values\":[null],\"valueMap\":{\"𐍈\":false},\"timestamps\":[\"9999-12-31T23:59:59.455Z\",\"0001-01-01T00:00:00.741985Z\"],\"durations\":[\"245587180235s\",\"315576000000.719s\"],\"empties\":[{}],\"nullValues\":[null,null],\"nullMap\":{\";@\":null}}" )
    , ( "codec.v1.WellKnown #5", "{\"any\":{\"@type\":\"type.googleapis.com/codec.v1.Repeated\"},\"duration\":\"0s\",\"empty\":{},\"valueMap\":{\",[\\n\\u0000 \":\"é$~\"},\"timestamps\":[\"1970-01-01T00:00:00Z\",\"0001-01-01T00:00:00.693Z\"],\"durations\":[\"-0.387677700s\"],\"empties\":[{}],\"structs\":{\"2147483647\":{}},\"nullValues\":[null]}" )
    , ( "codec.v1.WellKnown #6", "{\"struct\":{\"$~\":[-1.0693403351677307e-147,null],\"=&\\u0001/😀\":[{},[]]},\"list\":[[]],\"value\":null,\"timestamp\":\"1970-01-01T00:00:00Z\",\"duration\":\"0s\",\"mask\":\"\",\"empty\":{},\"values\":[-118],\"valueMap\":{\"\\n\":\"\",\">[\":\"<+\"},\"timestamps\":[\"1854-11-19T22:30:36Z\",\"0001-01-01T00:00:00.268608Z\"],\"structs\":{\"193\":{\"\\b\\n\":\".\",\"😀\":null}},\"nullValues\":[null,null],\"nullMap\":{\"#<\\u001f\":null,\"*✓𐍈\":null}}" )
    , ( "codec.v1.WellKnown #7", "{\"any\":{\"@type\":\"type.googleapis.com/google.protobuf.Duration\",\"value\":\"177988596997s\"},\"struct\":{},\"list\":[],\"value\":null,\"timestamp\":\"1970-01-01T00:00:00Z\",\"duration\":\"0s\",\"empty\":{},\"anys\":[{\"@type\":\"type.googleapis.com/codec.v1.Across\"}],\"valueMap\":{\"@?\\\\\":{}},\"timestamps\":[\"4920-09-30T01:19:54Z\"],\"empties\":[{},{}],\"structs\":{\"2099013785\":{},\"-1584825965\":{\"\":null,\"$\":[\"\"]}},\"nullValues\":[null,null],\"nullMap\":{\"\":null,\"%Z@!ß@[,\":null}}" )
    , ( "codec.v1.Everything #0", "{\"scalars\":{\"double\":2.6446168534308427e+36,\"float\":1.858138209270832e-12,\"int32\":-2066643397,\"uint32\":3356386852,\"sint64\":\"-5693193831550489292\",\"fixed32\":4229540842,\"fixed64\":\"644\",\"sfixed32\":-400680180,\"sfixed64\":\"-227\",\"bool\":true,\"string\":\"\\u001fΩ\u{007F}0=\",\"kind\":\"KIND_NEGATIVE\"},\"optionals\":{\"float\":-0.0006811943603679538,\"int32\":0,\"int64\":\"0\",\"uint64\":\"9223372036854775808\",\"string\":\"\",\"bytes\":\"\"},\"repeated\":{},\"maps\":{\"stringString\":{\"\":\"\\f\",\"\\f中\\r\":\"\"},\"int32Kind\":{\"-1338305716\":\"KIND_IMAGE\"},\"int64Double\":{\"-902433033187413002\":3.125},\"sint32Bool\":{\"1\":false,\"-305\":false},\"sint64Float\":{\"762\":-260736572503097340,\"851\":\"-Infinity\"},\"fixed32Uint64\":{\"1495862826\":\"1148252820239724260\",\"2867729276\":\"6264023189905751570\"},\"fixed64Leaf\":{\"9223372036854775808\":{}},\"sfixed32Bytes\":{\"1\":\"pQ==\",\"-1\":\"ZJha\"},\"sfixed64Int32\":{\"-9223372036854775808\":-1159237812},\"stringLeaf\":{\"\":{},\"\\u001fß(][\\u001f\\\\=\":{}}},\"tree\":{},\"wellKnown\":{\"any\":{\"@type\":\"type.googleapis.com/codec.v1.Leaf\"},\"struct\":{},\"value\":null,\"timestamp\":\"0001-01-01T00:00:00.509Z\",\"empty\":{},\"values\":[false,null],\"timestamps\":[\"2481-07-04T02:56:49.690Z\"],\"durations\":[\"-315576000000.357238582s\"],\"empties\":[{},{}],\"structs\":{\"289\":{\"\":{\"\":\"0(\"},\"!中✓𐍈~ *\\f\":{\"!\\r+<aΩ\\té\":3.0034667385942956e-58}},\"-2147483648\":{}},\"nullMap\":{\"%\\u0000\":null,\"\u{2028}<0=Ω(!\\\"\":null}},\"wrappers\":{}}" )
    , ( "codec.v1.Everything #1", "{\"optionals\":{},\"repeated\":{\"doubles\":[-91.375],\"floats\":[60.125,\"-Infinity\"],\"int32s\":[-646722063],\"int64s\":[\"898\",\"-9223372036854775808\"],\"uint64s\":[\"9223372036854775808\"],\"fixed32s\":[3550244822],\"bools\":[false],\"strings\":[\"9+$z~0é:\"],\"bytes\":[\"zbN0\"],\"kinds\":[\"KIND_UNSPECIFIED\",\"KIND_TEXT\"]},\"maps\":{\"stringString\":{\"\\r😀ß] \":\"*\u{2028}\",\"\u{2028}_\u{007F}\":\"é𐍈\"},\"int32Kind\":{\"-1602994905\":\"KIND_IMAGE\"},\"int64Double\":{\"763\":-9.288590428993801e+154},\"sint32Bool\":{\"2147483647\":true,\"-941\":false},\"fixed64Leaf\":{\"208\":{},\"3012147452373371919\":{}},\"boolString\":{\"false\":\"\u{007F}\"},\"boolLeaf\":{\"true\":{}}},\"choice\":{\"after\":-227,\"data\":\"I40S\"},\"names\":{},\"wellKnown\":{\"empty\":{}},\"wrappers\":{},\"more\":[{\"scalars\":{},\"repeated\":{},\"maps\":{},\"tree\":{},\"wrappers\":{},\"more\":[{},{}]},{\"optionals\":{},\"repeated\":{},\"choice\":{},\"outer\":{},\"tree\":{},\"wellKnown\":{\"empty\":{}},\"across\":{},\"more\":[{}]}]}" )
    , ( "codec.v1.Everything #2", "{\"optionals\":{\"float\":-1.3726901593755312e-14,\"int64\":\"-388446148463494603\",\"uint64\":\"11759582805282956144\",\"sint32\":1,\"string\":\"\",\"bytes\":\"\"},\"repeated\":{},\"names\":{},\"outer\":{},\"wellKnown\":{\"empty\":{}},\"wrappers\":{\"double\":0,\"float\":0,\"int32\":436,\"uint32\":0,\"bool\":false,\"string\":\"\",\"bytes\":\"\",\"int64s\":[\"-2624879478872003657\"],\"bytesMap\":{\",/\":\"CfzJhluq\",\";\\r(✓\\u0000\":\"1MAPuP8=\"}},\"more\":[{\"repeated\":{},\"maps\":{},\"outer\":{},\"tree\":{},\"more\":[{}]}]}" )
    , ( "codec.v1.Everything #3", "{\"scalars\":{},\"optionals\":{},\"repeated\":{\"doubles\":[1.7976931348623157e+308,-17.25],\"int32s\":[-846],\"uint64s\":[\"7256134194359879732\"],\"fixed32s\":[165247773,173083743],\"strings\":[\":-\",\"+\u{2028}\"],\"bytes\":[\"\"],\"kinds\":[\"KIND_IMAGE\"],\"leaves\":[{}]},\"maps\":{},\"choice\":{\"before\":\"*\\f\\\\\\u0000✓.~-\",\"after\":2147483647,\"twoWords\":\">>9*\u{007F}\"},\"outer\":{},\"tree\":{},\"wellKnown\":{\"struct\":{},\"list\":[[true,[]]],\"value\":null,\"duration\":\"0s\",\"mask\":\"k,b.eg6.ivyu,icQ5so\",\"empty\":{},\"values\":[false],\"valueMap\":{\"\":false,\"\u{2028}(\":\"*\"},\"timestamps\":[\"1970-01-01T00:00:00.471522230Z\"],\"durations\":[\"0.966688024s\",\"0.478025s\"],\"structs\":{\"761\":{\"𐍈@<(𐍈\":{\"\":\"✓\",\"\\b=@\":{}}},\"2147483647\":{\"\":\"=\\f9'z\",\"/<\":\"\"}},\"nullValues\":[null,null]},\"wrappers\":{\"double\":-7.541842769103872e+123,\"uint64\":\"8566933128438697652\",\"int32\":1,\"uint32\":24626795,\"bool\":false,\"string\":\"😀_ß&\u{2028}.>@\",\"bytes\":\"\",\"int64s\":[\"-9007199254740993\"],\"bytesMap\":{\"Ω\\\"\\u001f%+\":\"dNk=\"}}}" )
    , ( "codec.v1.Everything #4", "{\"scalars\":{},\"optionals\":{},\"repeated\":{},\"choice\":{\"after\":1260778408,\"none\":null},\"tree\":{\"label\":\"*Z9\",\"left\":{},\"children\":[{},{}]},\"more\":[{\"scalars\":{},\"optionals\":{},\"maps\":{},\"choice\":{},\"names\":{},\"outer\":{},\"tree\":{},\"wellKnown\":{\"empty\":{}},\"across\":{}},{\"optionals\":{},\"repeated\":{},\"choice\":{},\"outer\":{},\"tree\":{},\"wellKnown\":{\"empty\":{}},\"wrappers\":{},\"across\":{}}]}" )
    , ( "codec.v1.Everything #5", "{\"scalars\":{},\"optionals\":{},\"maps\":{},\"names\":{},\"wellKnown\":{\"any\":{\"@type\":\"type.googleapis.com/codec.v1.Tree\"},\"struct\":{},\"list\":[],\"value\":null,\"duration\":\"28124489901.199302350s\",\"mask\":\"\",\"empty\":{},\"anys\":[{\"@type\":\"type.googleapis.com/codec.v1.Outer\"}],\"values\":[null,-54.25],\"valueMap\":{\"\":\"~中9*.\",\"\u{2028}\":false},\"timestamps\":[\"5118-11-12T20:04:18.080950621Z\"],\"durations\":[\"-100483012606.769056s\",\"0.195s\"],\"structs\":{\"-1805657562\":{},\"-1\":{}},\"nullValues\":[null,null]},\"wrappers\":{},\"across\":{\"remote\":{},\"remotes\":[{},{}]},\"more\":[{\"optionals\":{},\"repeated\":{},\"maps\":{},\"outer\":{},\"more\":[{},{}]},{\"scalars\":{},\"optionals\":{},\"repeated\":{},\"maps\":{},\"choice\":{},\"names\":{},\"tree\":{},\"wellKnown\":{\"empty\":{}},\"wrappers\":{},\"across\":{},\"more\":[{}]}]}" )
    , ( "codec.v1.Everything #6", "{\"scalars\":{},\"repeated\":{\"floats\":[-2.2532504606039297e-32,116.5],\"int32s\":[387],\"int64s\":[\"4850443725798438452\"],\"fixed32s\":[1421320238,3890471289],\"bytes\":[\"9Br2RQ==\",\"nPM/11k=\"],\"leaves\":[{},{}]},\"maps\":{\"stringString\":{\"\":\"\u{007F}\",\"'/>:中\":\"✓&~\"},\"int32Kind\":{\"1\":\"KIND_TEXT\",\"-1\":\"KIND_UNSPECIFIED\"},\"int64Double\":{\"-8819405989624168709\":2.2250738585072014e-308,\"9007199254740993\":1.4992832525970701e-205},\"uint32Int64\":{\"2706448908\":\"-9223372036854775808\",\"2829241887\":\"9007199254740992\"},\"uint64String\":{\"13424301829899496557\":\" =:$😀$=%\",\"9223372036854775808\":\"\"},\"sint32Bool\":{\"174596799\":false,\"-752\":true},\"sint64Float\":{\"8528233160603701072\":123.25,\"9007199254740991\":0.000004130307388550136},\"fixed32Uint64\":{\"2818200541\":\"9007199254740993\",\"3621858429\":\"4223540650184231092\"},\"sfixed32Bytes\":{\"-916613383\":\"1g==\"},\"sfixed64Int32\":{\"9007199254740992\":1},\"boolString\":{\"false\":\"<\\n.@\\f\"},\"boolLeaf\":{\"false\":{}},\"stringLeaf\":{\">\\f<\":{}}},\"names\":{},\"outer\":{\"inner\":{},\"modes\":[\"MODE_UNSPECIFIED\",\"MODE_OFF\"],\"namedModes\":{\"é*\":\"MODE_ON\"}},\"tree\":{},\"wrappers\":{},\"more\":[{\"optionals\":{},\"maps\":{},\"tree\":{},\"wellKnown\":{\"empty\":{}},\"more\":[{},{}]}]}" )
    , ( "codec.v1.Everything #7", "{\"scalars\":{\"double\":-1.0490160396545546e+135,\"int64\":\"453\",\"uint64\":\"1\",\"sint32\":976,\"sint64\":\"-856558592707460546\",\"sfixed32\":654529737,\"kind\":\"KIND_TEXT\"},\"optionals\":{\"double\":9.838723040374272e-260,\"float\":\"NaN\",\"uint64\":\"16805340285521745741\",\"bool\":false,\"string\":\"9.\\\"\",\"kind\":\"KIND_UNSPECIFIED\"},\"repeated\":{},\"maps\":{\"sint32Bool\":{\"968114330\":false,\"-348860613\":true},\"sint64Float\":{\"-3519799320005503334\":-82.75},\"fixed32Uint64\":{\"275457420\":\"283\",\"2300231433\":\"28\"},\"fixed64Leaf\":{\"612\":{}},\"sfixed64Int32\":{\"9007199254740992\":848},\"boolLeaf\":{\"false\":{}}},\"choice\":{\"before\":\"[;/\\u0001(\",\"after\":512530684,\"wrapped\":1687659707},\"outer\":{\"inner\":{},\"inners\":[{},{}],\"modes\":[\"MODE_ON\"]},\"wellKnown\":{\"any\":{\"@type\":\"type.googleapis.com/codec.v1.Wrappers\"},\"value\":{\"\":{\"\":0.1,\"Ω\":-3.752256312613589e-172},\"😀\":false},\"duration\":\"0s\",\"mask\":\"\",\"empty\":{},\"timestamps\":[\"0001-01-01T00:00:00.762410515Z\"],\"durations\":[\"-315576000000.693429s\",\"1s\"],\"empties\":[{},{}],\"structs\":{\"-1\":{\"\\u001fA𐍈a~A.\\\\\":[\"A0@=(✓~&\",0.5],\"\\\"\":\"\\\\Ω)\"}},\"nullMap\":{\"_\":null,\"é\":null}}}" )
    ]
