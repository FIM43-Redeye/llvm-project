; RUN: llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -O0 -filetype=obj < %s -o %t.o
; RUN: llvm-dwarfdump --debug-info %t.o | FileCheck %s

; Verify that divergent (VGPR) debug values produce valid DWARF with
; lane-specific offset operations, and NOT DW_OP_LLVM_undefined.
;
; For a single-register value the explicit PushLane added by InstrEmitter must
; suppress the implicit one in DwarfExpression (no double application). For a
; multi-register value the lane offset is applied to each register piece
; independently (stride 4 = one VGPR lane), not once to the whole composite.

; --- i32 (single VGPR) ---
; CHECK:       DW_TAG_variable
; CHECK:       DW_AT_location
; CHECK-NEXT:  DW_OP_regx
; CHECK-SAME:  DW_OP_LLVM_push_lane
; CHECK-SAME:  DW_OP_lit4
; CHECK-SAME:  DW_OP_mul
; CHECK-SAME:  DW_OP_LLVM_offset
; Verify no double lane-offset (the per-operand guard must suppress implicit one).
; CHECK-NOT:   DW_OP_LLVM_push_lane
; CHECK-NOT:   DW_OP_LLVM_undefined
; CHECK:       DW_AT_name ("val")

; --- i64 (two VGPRs as DW_OP_piece composition) ---
; The lane offset is applied per register piece (each with stride 4), not once
; to the composed value.
; CHECK:       DW_TAG_variable
; CHECK:       DW_AT_location
; CHECK-NEXT:  DW_OP_regx
; CHECK-SAME:  DW_OP_LLVM_push_lane
; CHECK-SAME:  DW_OP_lit4
; CHECK-SAME:  DW_OP_mul
; CHECK-SAME:  DW_OP_LLVM_offset
; CHECK-SAME:  DW_OP_piece 0x4
; CHECK-SAME:  DW_OP_regx
; CHECK-SAME:  DW_OP_LLVM_push_lane
; CHECK-SAME:  DW_OP_lit4
; CHECK-SAME:  DW_OP_mul
; CHECK-SAME:  DW_OP_LLVM_offset
; CHECK-SAME:  DW_OP_piece 0x4
; CHECK-SAME:  DW_OP_LLVM_piece_end
; CHECK-NOT:   DW_OP_LLVM_undefined
; CHECK:       DW_AT_name ("val64")

define amdgpu_kernel void @test_vgpr_dwarf(ptr addrspace(1) %out) #0 !dbg !5 {
entry:
  %tid = call i32 @llvm.amdgcn.workitem.id.x(), !dbg !11
  %val = shl i32 %tid, 2, !dbg !12
    #dbg_value(i32 %val, !9, !DIExpression(DIOpArg(0, i32)), !12)
  store i32 %val, ptr addrspace(1) %out, align 4, !dbg !13
  ret void, !dbg !14
}

define amdgpu_kernel void @test_vgpr_dwarf_i64(ptr addrspace(1) %out) #0 !dbg !15 {
entry:
  %tid = call i32 @llvm.amdgcn.workitem.id.x(), !dbg !19
  %tid64 = zext i32 %tid to i64, !dbg !20
  %val = shl i64 %tid64, 2, !dbg !21
    #dbg_value(i64 %val, !17, !DIExpression(DIOpArg(0, i64)), !21)
  store i64 %val, ptr addrspace(1) %out, align 8, !dbg !22
  ret void, !dbg !23
}

declare i32 @llvm.amdgcn.workitem.id.x() #1

attributes #0 = { nounwind "target-features"="+wavefrontsize32" }
attributes #1 = { nounwind readnone speculatable }

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!3, !4}

!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: "clang", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug, enums: !2)
!1 = !DIFile(filename: "test.cl", directory: "/tmp")
!2 = !{}
!3 = !{i32 7, !"Dwarf Version", i32 5}
!4 = !{i32 2, !"Debug Info Version", i32 3}

; Function 1: test_vgpr_dwarf (i32)
!5 = distinct !DISubprogram(name: "test_vgpr_dwarf", scope: !1, file: !1, line: 1, type: !6, isLocal: false, isDefinition: true, scopeLine: 1, flags: DIFlagPrototyped, isOptimized: false, unit: !0, retainedNodes: !8)
!6 = !DISubroutineType(types: !7)
!7 = !{null}
!8 = !{!9}
!9 = !DILocalVariable(name: "val", scope: !5, file: !1, line: 2, type: !10)
!10 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!11 = !DILocation(line: 1, column: 1, scope: !5)
!12 = !DILocation(line: 2, column: 1, scope: !5)
!13 = !DILocation(line: 3, column: 1, scope: !5)
!14 = !DILocation(line: 4, column: 1, scope: !5)

; Function 2: test_vgpr_dwarf_i64 (i64 — two VGPR pieces)
!15 = distinct !DISubprogram(name: "test_vgpr_dwarf_i64", scope: !1, file: !1, line: 10, type: !6, isLocal: false, isDefinition: true, scopeLine: 10, flags: DIFlagPrototyped, isOptimized: false, unit: !0, retainedNodes: !16)
!16 = !{!17}
!17 = !DILocalVariable(name: "val64", scope: !15, file: !1, line: 11, type: !18)
!18 = !DIBasicType(name: "long", size: 64, encoding: DW_ATE_signed)
!19 = !DILocation(line: 10, column: 1, scope: !15)
!20 = !DILocation(line: 11, column: 1, scope: !15)
!21 = !DILocation(line: 12, column: 1, scope: !15)
!22 = !DILocation(line: 13, column: 1, scope: !15)
!23 = !DILocation(line: 14, column: 1, scope: !15)
