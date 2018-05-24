port module Main exposing (..)

{-| -}

import AnimationFrame
import Color
import Dict exposing (Dict)
import Element
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Expect
import Fuzz
import Html exposing (Html)
import List.Extra
import Random
import Test
import Test.Runner
import Test.Runner.Failure
import Testable
import Tests exposing (Testable)
import Time exposing (Time)


init : ( Model Msg, Cmd Msg )
init =
    ( { current = Nothing
      , upcoming =
            Tests.tests

      -- generateTests (Random.initialSeed 227852860) 1
      , finished = []
      , stage = BeginRendering
      }
    , Cmd.none
    )


main : Program Never (Model Msg) Msg
main =
    Html.program
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }


type alias Model msg =
    { current : Maybe (Testable msg)
    , upcoming : List (Testable msg)
    , finished : List (Testable msg)
    , stage : Stage
    }


type Msg
    = NoOp
    | Tick Time
    | RefreshBoundingBox
        (List
            { id : String
            , bbox : Testable.BoundingBox
            , style : Testable.Style
            }
        )


type Stage
    = Rendered
    | BeginRendering
    | GatherData
    | Finished


runTest : Dict String Testable.Found -> Testable msg -> Testable msg
runTest boxes test =
    let
        tests =
            Testable.toTest test.label boxes test.element

        seed =
            Random.initialSeed 227852860

        results =
            Testable.runTests seed (Debug.log "created Tests" tests)
                |> Debug.log "run tests"
    in
    { test | results = Just results }


generateTests : Random.Seed -> Int -> List (Testable msg)
generateTests seed num =
    if num <= 0 then
        []
    else
        let
            ( testable, newSeed ) =
                generateTest seed
        in
        testable :: generateTests newSeed (num - 1)


generateTest : Random.Seed -> ( Testable msg, Random.Seed )
generateTest seed =
    testableLayout
        |> Test.Runner.fuzz
        |> flip Random.step seed
        |> (\( ( val, shrinker ), newSeed ) -> ( val, seed ))


update : Msg -> Model Msg -> ( Model Msg, Cmd Msg )
update msg model =
    case msg of
        NoOp ->
            ( model, Cmd.none )

        RefreshBoundingBox boxes ->
            case model.current of
                Nothing ->
                    ( { model | stage = Finished }
                    , Cmd.none
                    )

                Just current ->
                    let
                        toTuple box =
                            ( box.id, { style = box.style, bbox = box.bbox } )

                        foundData =
                            boxes
                                |> List.map toTuple
                                |> Dict.fromList

                        currentResults =
                            runTest foundData current
                    in
                    case model.upcoming of
                        [] ->
                            ( { model
                                | stage = Finished
                                , current = Nothing
                                , finished = currentResults :: model.finished
                              }
                            , Cmd.none
                            )

                        newCurrent :: remaining ->
                            ( { model
                                | finished = currentResults :: model.finished
                                , stage = BeginRendering
                              }
                            , Cmd.none
                            )

        Tick time ->
            case model.stage of
                BeginRendering ->
                    case model.upcoming of
                        [] ->
                            ( { model | stage = Rendered }
                            , Cmd.none
                            )

                        current :: remaining ->
                            ( { model
                                | stage = Rendered
                                , upcoming = remaining
                                , current = Just current
                              }
                            , Cmd.none
                            )

                Rendered ->
                    case model.current of
                        Nothing ->
                            ( { model | stage = Finished }
                            , Cmd.none
                            )

                        Just test ->
                            ( { model | stage = GatherData }
                            , analyze (Testable.getIds test.element)
                            )

                _ ->
                    ( { model | stage = Rendered }
                    , Cmd.none
                    )


subscriptions : { a | stage : Stage } -> Sub Msg
subscriptions model =
    Sub.batch
        [ styles RefreshBoundingBox
        , case model.stage of
            BeginRendering ->
                AnimationFrame.times Tick

            Rendered ->
                AnimationFrame.times Tick

            _ ->
                Sub.none
        ]


port analyze : List String -> Cmd msg


port styles : (List { id : String, bbox : Testable.BoundingBox, style : Testable.Style } -> msg) -> Sub msg


view : Model Msg -> Html Msg
view model =
    case model.current of
        Nothing ->
            if model.stage == Finished then
                Element.layout [] <|
                    Element.column
                        [ Element.spacing 20
                        , Element.padding 20
                        , Element.width (Element.px 800)

                        -- , Background.color Color.grey
                        ]
                        (List.map viewResult model.finished)
            else
                Html.text "running?"

        Just current ->
            Testable.render current.element


viewResult : Testable Msg -> Element.Element Msg
viewResult testable =
    let
        viewSingle result =
            case result of
                ( label, Nothing ) ->
                    Element.el
                        [ Background.color Color.green
                        , Font.color Color.white
                        , Element.paddingXY 20 10
                        , Element.alignLeft
                        , Border.rounded 3
                        ]
                    <|
                        Element.text (label ++ " - " ++ "Success!")

                ( label, Just { given, description, reason } ) ->
                    Element.row
                        [ Background.color Color.red
                        , Font.color Color.white
                        , Element.paddingXY 20 10
                        , Element.alignLeft
                        , Element.spacing 25
                        , Border.rounded 3
                        ]
                        [ Element.el [ Element.width Element.fill ] <| Element.text label

                        -- , Element.el [ Element.width Element.fill ] <| Element.text description
                        , Element.el [ Element.width Element.fill ] <| Element.text (toString reason)
                        ]
    in
    Element.column
        [ Border.width 1
        , Border.color Color.lightGrey
        , Element.padding 20
        , Element.height Element.shrink
        , Element.alignLeft
        ]
        [ Element.el [ Font.bold ] (Element.text testable.label)
        , Element.column [ Element.alignLeft, Element.spacing 20 ]
            (case testable.results of
                Nothing ->
                    [ Element.text "no results" ]

                Just results ->
                    List.map viewSingle results
            )
        ]


{--}
type alias Testable msg =
    { element : Testable.Element msg
    , label : String
    , results :
        Maybe
            (List
                ( String
                , Maybe
                    { given : Maybe String
                    , description : String
                    , reason : Test.Runner.Failure.Reason
                    }
                )
            )
    }


attr tag label attr test =
    Testable.Batch
        [ Testable.Attr attr
        , Testable.AttrTest
            (\found ->
                Test.test (tag ++ ": " ++ label) <|
                    \_ -> test found
            )
        ]


widthFill tag =
    attr tag
        "width fill"
        (Element.width Element.fill)
        (\context ->
            let
                spacePerPortion =
                    context.parent.bbox.width / toFloat (List.length context.siblings + 1)
            in
            Expect.equal spacePerPortion context.self.bbox.width
        )


heightFill tag =
    attr tag
        "height fill"
        (Element.height Element.fill)
        (\context ->
            let
                spacePerPortion =
                    context.parent.bbox.height / toFloat (List.length context.siblings + 1)
            in
            Expect.equal spacePerPortion context.self.bbox.height
        )


heightPx px tag =
    attr tag
        ("height at " ++ toString px ++ "px")
        (Element.height (Element.px (round px)))
        (\found ->
            Expect.equal found.self.bbox.height px
        )


widthPx px tag =
    attr tag
        ("width at " ++ toString px ++ "px")
        (Element.width (Element.px (round px)))
        (\found ->
            Expect.equal found.self.bbox.width px
        )


type alias PossibleAttributes msg =
    { width : String -> Testable.Attr msg
    , height : String -> Testable.Attr msg
    }


possibleToList str { width, height } =
    width str :: height str :: []


availableAttributes : { width : Float, height : Float } -> Fuzz.Fuzzer (PossibleAttributes msg)
availableAttributes bounds =
    Fuzz.map2 PossibleAttributes
        (Fuzz.oneOf
            (List.map Fuzz.constant (widths bounds.width))
        )
        (Fuzz.oneOf
            (List.map Fuzz.constant (heights bounds.height))
        )


widths : Float -> List (String -> Testable.Attr msg)
widths width =
    [ \tag ->
        attr tag
            (" with width at " ++ toString width ++ "px")
            (Element.width (Element.px (round width)))
            (\found ->
                Expect.equal found.self.bbox.width width
            )
    , \tag ->
        attr tag
            " with width fill"
            (Element.width Element.fill)
            (\context ->
                let
                    -- {-|
                    -- Calculation is
                    --     totalparentwidth - (paddingLeft ++ paddingRight)
                    --      minus widths of all the other children
                    -- -}
                    otherWidth =
                        -- Debug.log "width" <|
                        List.sum <|
                            -- Debug.log "widths" <|
                            List.map (\child -> child.bbox.width) context.siblings

                    spacePerPortion =
                        context.parent.bbox.width - otherWidth
                in
                Expect.equal spacePerPortion context.self.bbox.width
            )
    ]


heights : Float -> List (String -> Testable.Attr msg)
heights height =
    [ \tag ->
        attr tag
            (" with height at " ++ toString height ++ "px")
            (Element.height (Element.px (round height)))
            (\found ->
                Expect.equal found.self.bbox.height height
            )
    , \tag ->
        attr tag
            " with height fill"
            (Element.height Element.fill)
            (\context ->
                let
                    -- {-|
                    -- Calculation is
                    --     totalparentwidth - (paddingLeft ++ paddingRight)
                    --      minus widths of all the other children
                    -- -}
                    otherHeight =
                        List.sum <|
                            List.map (\child -> child.bbox.height) context.siblings

                    spacePerPortion =
                        context.parent.bbox.height - otherHeight
                in
                Expect.equal spacePerPortion context.self.bbox.height
            )
    ]


content : Testable.Element msg
content =
    Testable.El
        [ Testable.Attr <| Element.width (Element.px 20)
        , Testable.Attr <| Element.height (Element.px 20)
        ]
        Testable.Empty


tests : List (Testable msg)
tests =
    [ { label = "Width/Height 200"
      , results = Nothing
      , element =
            Testable.El
                [ widthPx 200 "single element"
                , heightPx 200 "single element"
                ]
                Testable.Empty
      }
    , { label = "Width Fill/Height Fill - 1"
      , results = Nothing
      , element =
            Testable.El
                [ widthFill "single element"
                , heightFill "single element"
                ]
            <|
                content
      }
    , { label = "Width Fill/Height Fill - 2"
      , results = Nothing
      , element =
            Testable.El
                [ widthFill "top element"
                , heightFill "top element"
                ]
            <|
                Testable.El
                    [ widthFill "embedded element"
                    , heightFill "embedded element"
                    ]
                <|
                    content
      }
    , { label = "Row Width Fill/Height Fill"
      , results = Nothing
      , element =
            Testable.Row
                [ widthFill "on row"
                , heightFill "on row"
                ]
                [ Testable.El
                    [ widthFill "row - 1"
                    , heightFill "row - 1"
                    ]
                    content
                , Testable.El
                    [ widthFill "row - 2"
                    , heightFill "row - 2"
                    ]
                    content
                , Testable.El
                    [ widthFill "row - 3"
                    , heightFill "row - 3"
                    ]
                    content
                ]
      }
    ]



{- Generating A Complete Test Suite

-}


type TestableElement
    = El
    | Row
    | Column


allIndividualTestables : List (Fuzz.Fuzzer TestableElement)
allIndividualTestables =
    [ Fuzz.constant El
    , Fuzz.constant Row
    , Fuzz.constant Column
    ]


testableLayout : Fuzz.Fuzzer (Testable msg)
testableLayout =
    let
        asTestable layout =
            { element = layout
            , label = "A Sweet Test"
            , results = Nothing
            }
    in
    Fuzz.map asTestable layout


layout : Fuzz.Fuzzer (Testable.Element msg)
layout =
    Fuzz.map4 createContainer
        (Fuzz.tuple3
            ( availableAttributes { width = 20, height = 20 }
            , availableAttributes { width = 20, height = 20 }
            , availableAttributes { width = 20, height = 20 }
            )
        )
        (availableAttributes { width = 200, height = 200 })
        (Fuzz.oneOf allIndividualTestables)
        (Fuzz.oneOf allIndividualTestables)


createElement : String -> TestableElement -> PossibleAttributes msg -> Testable.Element msg
createElement tag layout possibleAttrs =
    let
        attrs =
            possibleToList tag possibleAttrs
    in
    case layout of
        El ->
            Testable.El attrs content

        Row ->
            Testable.Row attrs
                [ content
                , content
                , content
                ]

        Column ->
            Testable.Column attrs
                [ content
                , content
                , content
                ]


createContainer : ( PossibleAttributes msg, PossibleAttributes msg, PossibleAttributes msg ) -> PossibleAttributes msg -> TestableElement -> TestableElement -> Testable.Element msg
createContainer ( a1, a2, a3 ) possibleAttrs parent child =
    let
        attrs =
            possibleToList "0" possibleAttrs
    in
    case parent of
        El ->
            Testable.El attrs (createElement "0-0" child a1)

        Row ->
            Testable.Row attrs
                [ createElement "0-0" child a1
                , createElement "0-1" child a2
                , createElement "0-2" child a3
                ]

        Column ->
            Testable.Column attrs
                [ createElement "0-0" child a1
                , createElement "0-1" child a2
                , createElement "0-2" child a3
                ]


{-| Given a list of a list of possibilities,

choose once from each list.

    [ [width (px 100), width fill]
    , [height (px 100), height fill]
    ]
    ->

    [ [width (px 100), height (px 100)]
    , [width (px 100), height fill]
    ]

-}
allPossibilities : List (List a) -> List (List a)
allPossibilities =
    List.Extra.cartesianProduct
