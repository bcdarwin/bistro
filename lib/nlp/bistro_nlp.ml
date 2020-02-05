open Bistro
open Shell_dsl

let wikipedia_summary q : text file =
  let url = "https://en.wikipedia.org/api/rest_v1/page/summary/" ^ q in
  Workflow.shell ~descr:"nlp.wikipedia_summary" [
    pipe [
      cmd "curl" [
        quote ~using:'\'' (string url) ;
      ] ;
      cmd "sed" ~stdout:dest [ string {|-n 's/.*"extract":"\(.*\)","extract_html.*/\1/p'|} ] ;
    ]
  ]

module Stanford_parser = struct
  let img = [ docker_image ~account:"pveber" ~name:"stanford-parser" ~tag:"3.9.1" () ]

  class type deps = object
    inherit text
    method format : [`stanford_parser_deps]
  end

  let lexparser (x : text file) : deps file =
    Workflow.shell ~descr:"stanford_parser" [
      cmd ~img "lexparser.sh" ~stdout:dest [ dep x ]
    ]

  let dependensee (x : deps file) : png file =
    Workflow.shell ~descr:"stanford_dependensee" [
      cmd "java" ~img [
        opt "-cp" string "/usr/bin/DependenSee.2.0.5.jar:/usr/bin/stanford-parser.jar:/usr/bin/stanford-parser-3.3.0-models.jar" ;
        string "com.chaoticity.dependensee.Main" ;
        opt "-t" dep x ;
        dest ;
      ]
    ]
end
