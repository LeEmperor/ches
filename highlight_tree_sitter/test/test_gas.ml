open! Core
open Ches_highlight
open Ches_highlight_tree_sitter

let run provider source =
  let key = Provider.key provider ~document:(Snapshot.Document_id.create ()) ~revision:0 in
  let result = Provider.highlight provider ~key ~source in
  assert (Snapshot.matches result.snapshot key);
  result
;;

let check_slice source (result : Provider.result) token category =
  let slices =
    List.map (Snapshot.ranges result.snapshot) ~f:(fun range ->
      String.sub source ~pos:range.start ~len:(range.stop - range.start), range.category)
  in
  if not (List.exists slices ~f:(fun (text, cat) ->
    String.equal text token && Category.equal cat category))
  then raise_s [%sexp "missing GAS capture", (token : string),
    (category : Category.t), (slices : (string * Category.t) list)]
;;

let fixture =
  ".file \"example.c\"\n\
   .text\n\
   .globl main\n\
   .type main, @function\n\
   foo = 1\n\
   main:\n\
   .LFB0:\n\
   .cfi_startproc\n\
   # é: compiler-ish fixture\n\
   pushq %rbp\n\
   movq %rsp, %rbp\n\
   movl $42, %eax\n\
   movq $foo+8, %rax\n\
   leaq foo+8(%rip), %rdi\n\
   movq foo@GOTPCREL(%rip), %rax\n\
   call puts@PLT\n\
   lock addl $1, (%rax)\n\
   0:\n\
   1: jne 1b\n\
   jmp 2f\n\
   .long 1f - 0f\n\
   1: nop\n\
   2: popq %rbp\n\
   ret\n\
   .cfi_endproc\n\
   .size main, .-main\n\
   .section .rodata\n\
   .string \"hello é\"\n\
   /* block comment */\n"
;;

let%test_unit "GAS compiler fixture, local labels, assignments and address expressions" =
  let provider = Provider.create ~language:Gas in
  let result = run provider fixture in
  assert (Provider.Status.equal result.status (Highlighted { syntax_errors = false }));
  List.iter
    [ ".text", Category.Keyword; "movq", Keyword; "lock", Keyword
    ; "%rax", Constant; "main:", Function; ".LFB0:", Function; "1:", Function
    ; "1b", Function; "2f", Function; "1f", Function; "0f", Function
    ; "foo", Variable; "42", Number; "8", Number; "1", Number
    ; "\"hello é\"", String; "@PLT", Property; "@GOTPCREL", Property
    ; "@function", Property; "# é: compiler-ish fixture", Comment
    ; "/* block comment */", Comment; "+", Operator
    ] ~f:(fun (token, category) -> check_slice fixture result token category);
  let empty = run provider "" in
  assert (Provider.Status.equal empty.status (Highlighted { syntax_errors = false }));
  [%test_result: Snapshot.Range.t list] (Snapshot.ranges empty.snapshot) ~expect:[];
  Provider.close provider
;;

let%test_unit "GAS patch forms and existing operand forms parse independently at EOF" =
  let provider = Provider.create ~language:Gas in
  List.iter
    [ "1:"; "12: jmp 12b"; "jmp 2f"; ".long 1f - 0f"; "foo = 1"
    ; "foo = (bar+8)"; "movq $foo+8, %rax"; "leaq foo+8(%rip), %rax"
    ; "movq -8(%rbp,%rcx,4), %rax"; "call *%rax"; "movq $0xff, %rax"
    ; "movq $-8, %rax"; ".double 0f1.5"; "movq 0f1.5, %rax"
    ; ".byte 'a'"; ".p2align 4,,10"; ".section .note.GNU-stack,\"\",@progbits"
    ] ~f:(fun source ->
      let result = run provider source in
      if not (Provider.Status.equal result.status (Highlighted { syntax_errors = false }))
      then raise_s [%sexp "GAS form failed", (source : string), (result.status : Provider.Status.t)]);
  Provider.close provider
;;

let%test_unit "GAS error recovery highlights subsequent valid instructions" =
  let provider = Provider.create ~language:Gas in
  let source = "movq $foo+, %rax\n.text\nnext:\n movl $7, %eax\n ret\n" in
  let result = run provider source in
  assert (Provider.Status.equal result.status (Highlighted { syntax_errors = true }));
  List.iter [ ".text", Category.Keyword; "next:", Function; "movl", Keyword
            ; "7", Number; "%eax", Constant; "ret", Keyword ]
    ~f:(fun (token, category) -> check_slice source result token category);
  Provider.close provider
;;

let debug_fixture =
  ".file \"example.c\"\n\
   .file 1 \"example.c\"\n\
   .file 2 \"/tmp/source dir\" \"example.c\"\n\
   .file 0 \"/tmp\" \"example.c\" md5 0x123456789abcdef\n\
   .loc 1 7 0\n\
   movl $42, %eax\n\
   .loc\t1\t8\t3 is_stmt 0 discriminator 2 # debug options\r\n\
   addl $1, %eax\n\
   .loc 1 9 0 basic_block prologue_end epilogue_begin isa 0\n\
   .loc 1 10 0 is_stmt 1 view -0\n\
   .loc 1 11 0 view .LVU1\n\
   ret\n\
   .long 1f - 0f, foo + 8, foo - 8, foo -8, 1 - 2\n\
   .p2align 4,,10\n"
;;

let%test_unit "GAS debug directives preserve following instructions and arithmetic" =
  let provider = Provider.create ~language:Gas in
  let result = run provider debug_fixture in
  assert (Provider.Status.equal result.status (Highlighted { syntax_errors = false }));
  List.iter
    [ ".file", Category.Keyword; ".loc", Keyword; "movl", Keyword
    ; "addl", Keyword; "ret", Keyword; "%eax", Constant; "42", Number
    ; "-0", Number; "view", Variable; ".LVU1", Variable
    ; "\"/tmp/source dir\"", String; "0x123456789abcdef", Number
    ; "1f", Function; "0f", Function; "+", Operator; "-", Operator
    ] ~f:(fun (token, category) -> check_slice debug_fixture result token category);
  (* Each subtraction must remain a binary expression, not a signed list atom. *)
  let minus_count =
    List.count (Snapshot.ranges result.snapshot) ~f:(fun range ->
      Category.equal range.category Operator
      && String.equal
        (String.sub debug_fixture ~pos:range.start ~len:(range.stop - range.start)) "-")
  in
  [%test_result: int] minus_count ~expect:4;
  List.iter
    [ ".file 1 \"example.c\""; ".file 2 \"/tmp\" \"example.c\""
    ; ".file 1 \"example.c\"   "; ".loc 1 2 0   "
    ; ".loc 1 2 0"; ".loc 1 2 0 is_stmt 0 view -0"
    ] ~f:(fun source ->
      let result = run provider source in
      assert (Provider.Status.equal result.status (Highlighted { syntax_errors = false })));
  Provider.close provider
;;

let%test_unit "GAS incremental edits equal fresh parses and leave old snapshots unchanged" =
  let provider = Provider.create ~language:Gas in
  let fresh = Provider.create ~language:Gas in
  let document = Snapshot.Document_id.create () in
  let sources =
    [ fixture; String.substr_replace_all fixture ~pattern:"foo+8" ~with_:"foo+16"
    ; String.substr_replace_all fixture ~pattern:"1b" ~with_:"2f"
    ; "/*\n" ^ fixture; "/*\n" ^ fixture ^ "*/\n"; fixture
    ; String.substr_replace_all fixture ~pattern:"é" ~with_:"😀"
     ; "movq $foo+, %rax\nret\n"; ""; debug_fixture
     ; String.substr_replace_all debug_fixture ~pattern:"view -0" ~with_:"view 1"
     ; fixture; "\n" ^ fixture; fixture ]
  in
  let history =
    List.mapi sources ~f:(fun revision source ->
      let key = Provider.key provider ~document ~revision in
      let actual = Provider.highlight_incremental provider ~key ~source in
      let expected = Provider.highlight fresh ~key ~source in
      assert (Provider.Status.equal actual.status expected.status);
      assert (match actual.status with Highlighted _ -> true | Plain _ -> false);
      [%test_result: Snapshot.Range.t list] (Snapshot.ranges actual.snapshot)
        ~expect:(Snapshot.ranges expected.snapshot);
      actual.snapshot, Snapshot.ranges actual.snapshot)
  in
  assert (Provider.incremental_count provider = List.length sources - 1);
  List.iter history ~f:(fun (snapshot, ranges) ->
    [%test_result: Snapshot.Range.t list] (Snapshot.ranges snapshot) ~expect:ranges);
  Provider.close provider;
  Provider.close fresh
;;
