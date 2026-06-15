; RUN: llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -O0 -stop-after=finalize-isel < %s | FileCheck %s
; RUN: llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -O0 -filetype=obj < %s -o %t.o
; RUN: llvm-dwarfdump --debug-info %t.o | FileCheck %s --check-prefix=DWARF

; Test that DBG_VALUE_LIST instructions with multiple divergent operands
; get lane-specific byte offset operations added for EACH divergent arg.
; Both %a and %b have independent uses (stores) to prevent ISel from
; folding them away, which would invalidate the variadic debug value.

; CHECK-LABEL: name: test_vgpr_dbg_value_list
; CHECK: DBG_VALUE_LIST !{{[0-9]+}}, !DIExpression(DIOpArg(0, i32), DIOpPushLane(i32), DIOpConstant(i32 4), DIOpMul(), DIOpByteOffset(i32), DIOpArg(1, i32), DIOpPushLane(i32), DIOpConstant(i32 4), DIOpMul(), DIOpByteOffset(i32), DIOpAdd())

define amdgpu_kernel void @test_vgpr_dbg_value_list(ptr addrspace(1) %out1, ptr addrspace(1) %out2) #0 !dbg !5 {
entry:
  %tid = call i32 @llvm.amdgcn.workitem.id.x(), !dbg !11
  %a = shl i32 %tid, 2, !dbg !12
  %b = mul i32 %tid, 3, !dbg !12
    #dbg_value(!DIArgList(i32 %a, i32 %b), !9, !DIExpression(DIOpArg(0, i32), DIOpArg(1, i32), DIOpAdd()), !13)
  store i32 %a, ptr addrspace(1) %out1, align 4, !dbg !14
  store i32 %b, ptr addrspace(1) %out2, align 4, !dbg !15
  ret void, !dbg !16
}

; Test that a mix of divergent (VGPR) and uniform (SGPR) operands in a
; DBG_VALUE_LIST only adds lane offset for the divergent arg (arg 0),
; while the uniform arg (arg 1, workgroup.id = SGPR) remains unchanged.
; Both values must have independent uses (stores) to prevent folding.

; CHECK-LABEL: name: test_vgpr_sgpr_mixed_list
; CHECK: DBG_VALUE_LIST !{{[0-9]+}}, !DIExpression(DIOpArg(0, i32), DIOpPushLane(i32), DIOpConstant(i32 4), DIOpMul(), DIOpByteOffset(i32), DIOpArg(1, i32), DIOpAdd())

define amdgpu_kernel void @test_vgpr_sgpr_mixed_list(ptr addrspace(1) %out1, ptr addrspace(1) %out2) #0 !dbg !17 {
entry:
  %tid = call i32 @llvm.amdgcn.workitem.id.x(), !dbg !22
  %gid = call i32 @llvm.amdgcn.workgroup.id.x(), !dbg !22
  %divergent = shl i32 %tid, 2, !dbg !23
  %uniform = add i32 %gid, 1, !dbg !23
    #dbg_value(!DIArgList(i32 %divergent, i32 %uniform), !20, !DIExpression(DIOpArg(0, i32), DIOpArg(1, i32), DIOpAdd()), !24)
  store i32 %divergent, ptr addrspace(1) %out1, align 4, !dbg !25
  store i32 %uniform, ptr addrspace(1) %out2, align 4, !dbg !26
  ret void, !dbg !27
}

; Test a mix of a single-register (i32) and a multi-register (i64) divergent
; operand. Only the single-register operand (arg 0) gets explicit lane ops at
; ISel; the multi-register i64 operand (arg 1) is left unchanged and handled
; per-register at DWARF emission. This also verifies the builder finds the
; first DIOpArg and inserts ops at the right position without disturbing arg 1.

; CHECK-LABEL: name: test_mixed_stride_list
; CHECK: DBG_VALUE_LIST !{{[0-9]+}}, !DIExpression(DIOpArg(0, i32), DIOpPushLane(i32), DIOpConstant(i32 4), DIOpMul(), DIOpByteOffset(i32), DIOpZExt(i64), DIOpArg(1, i64), DIOpAdd())

; In the final DWARF, the single-register operand's explicit lane ops must NOT
; suppress the multi-register operand's per-register lane offset: the i64 value
; must get one PushLane/offset per VGPR piece. The pattern below (a piece, then
; another reg with its own push_lane/offset and piece, then piece_end) is
; unique to the i64 composite and would be absent if the implicit per-register
; offset were wrongly suppressed for this operand.
; DWARF: DW_OP_piece 0x4, DW_OP_regx {{0x[0-9a-f]+}}, DW_OP_LLVM_user DW_OP_LLVM_push_lane, DW_OP_lit4, DW_OP_mul, DW_OP_LLVM_user DW_OP_LLVM_offset, DW_OP_piece 0x4, DW_OP_LLVM_user DW_OP_LLVM_piece_end

define amdgpu_kernel void @test_mixed_stride_list(ptr addrspace(1) %out1, ptr addrspace(1) %out2) #0 !dbg !28 {
entry:
  %tid = call i32 @llvm.amdgcn.workitem.id.x(), !dbg !33
  %a = shl i32 %tid, 2, !dbg !34
  %tid64 = zext i32 %tid to i64, !dbg !34
  %b = shl i64 %tid64, 3, !dbg !34
    #dbg_value(!DIArgList(i32 %a, i64 %b), !31, !DIExpression(DIOpArg(0, i32), DIOpZExt(i64), DIOpArg(1, i64), DIOpAdd()), !35)
  store i32 %a, ptr addrspace(1) %out1, align 4, !dbg !36
  store i64 %b, ptr addrspace(1) %out2, align 8, !dbg !37
  ret void, !dbg !38
}

declare i32 @llvm.amdgcn.workitem.id.x() #1
declare i32 @llvm.amdgcn.workgroup.id.x() #1

attributes #0 = { nounwind "target-features"="+wavefrontsize32" }
attributes #1 = { nounwind readnone speculatable }

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!3, !4}

!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: "clang", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug, enums: !2)
!1 = !DIFile(filename: "test_list.cl", directory: "/tmp")
!2 = !{}
!3 = !{i32 7, !"Dwarf Version", i32 5}
!4 = !{i32 2, !"Debug Info Version", i32 3}
!5 = distinct !DISubprogram(name: "test_vgpr_dbg_value_list", scope: !1, file: !1, line: 1, type: !6, isLocal: false, isDefinition: true, scopeLine: 1, flags: DIFlagPrototyped, isOptimized: false, unit: !0, retainedNodes: !8)
!6 = !DISubroutineType(types: !7)
!7 = !{null}
!8 = !{!9}
!9 = !DILocalVariable(name: "sum", scope: !5, file: !1, line: 4, type: !10)
!10 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!11 = !DILocation(line: 1, column: 1, scope: !5)
!12 = !DILocation(line: 2, column: 1, scope: !5)
!13 = !DILocation(line: 3, column: 1, scope: !5)
!14 = !DILocation(line: 4, column: 1, scope: !5)
!15 = !DILocation(line: 5, column: 1, scope: !5)
!16 = !DILocation(line: 6, column: 1, scope: !5)

; Function 2: test_vgpr_sgpr_mixed_list
!17 = distinct !DISubprogram(name: "test_vgpr_sgpr_mixed_list", scope: !1, file: !1, line: 10, type: !6, isLocal: false, isDefinition: true, scopeLine: 10, flags: DIFlagPrototyped, isOptimized: false, unit: !0, retainedNodes: !18)
!18 = !{!20}
!20 = !DILocalVariable(name: "mixed_sum", scope: !17, file: !1, line: 11, type: !10)
!22 = !DILocation(line: 10, column: 1, scope: !17)
!23 = !DILocation(line: 11, column: 1, scope: !17)
!24 = !DILocation(line: 12, column: 1, scope: !17)
!25 = !DILocation(line: 13, column: 1, scope: !17)
!26 = !DILocation(line: 14, column: 1, scope: !17)
!27 = !DILocation(line: 15, column: 1, scope: !17)

; Function 3: test_mixed_stride_list (single-register i32 + multi-register i64)
!28 = distinct !DISubprogram(name: "test_mixed_stride_list", scope: !1, file: !1, line: 20, type: !6, isLocal: false, isDefinition: true, scopeLine: 20, flags: DIFlagPrototyped, isOptimized: false, unit: !0, retainedNodes: !29)
!29 = !{!31}
!30 = !DIBasicType(name: "long", size: 64, encoding: DW_ATE_signed)
!31 = !DILocalVariable(name: "result", scope: !28, file: !1, line: 21, type: !30)
!33 = !DILocation(line: 20, column: 1, scope: !28)
!34 = !DILocation(line: 21, column: 1, scope: !28)
!35 = !DILocation(line: 22, column: 1, scope: !28)
!36 = !DILocation(line: 23, column: 1, scope: !28)
!37 = !DILocation(line: 24, column: 1, scope: !28)
!38 = !DILocation(line: 25, column: 1, scope: !28)
