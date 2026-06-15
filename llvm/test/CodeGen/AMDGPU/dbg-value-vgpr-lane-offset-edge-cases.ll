; RUN: llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -O0 -stop-after=finalize-isel < %s | FileCheck %s

; Test edge cases for divergent debug value lane offset transformation.

; Test 1: i8 type - on AMDGPU, i8 is promoted to i16, but both fit in VGPR_32
; so the lane stride is 4 bytes (register width), not 1 or 2 bytes (type size).
; Note: DIOpArg has i8 (original IR type) while DIOpByteOffset has i16 (EVT after
; target promotion), because the byte offset is computed from the register-level type.
; CHECK-LABEL: name: test_vgpr_dbg_value_i8
; CHECK: DBG_VALUE %{{[0-9]+}}, $noreg, !{{[0-9]+}}, !DIExpression(DIOpArg(0, i8), DIOpPushLane(i32), DIOpConstant(i32 4), DIOpMul(), DIOpByteOffset(i16))

define amdgpu_kernel void @test_vgpr_dbg_value_i8(ptr addrspace(1) %out) #0 !dbg !5 {
entry:
  %tid = call i32 @llvm.amdgcn.workitem.id.x(), !dbg !11
  %tid8 = trunc i32 %tid to i8, !dbg !12
  %val = add i8 %tid8, 1, !dbg !13
    #dbg_value(i8 %val, !9, !DIExpression(DIOpArg(0, i8)), !13)
  store i8 %val, ptr addrspace(1) %out, align 1, !dbg !14
  ret void, !dbg !15
}

; Test 2: half type (16-bit float) - fits in VGPR_32, so lane stride is 4 bytes
; CHECK-LABEL: name: test_vgpr_dbg_value_half
; CHECK: DBG_VALUE %{{[0-9]+}}, $noreg, !{{[0-9]+}}, !DIExpression(DIOpArg(0, half), DIOpPushLane(i32), DIOpConstant(i32 4), DIOpMul(), DIOpByteOffset(half))

define amdgpu_kernel void @test_vgpr_dbg_value_half(ptr addrspace(1) %out) #0 !dbg !16 {
entry:
  %tid = call i32 @llvm.amdgcn.workitem.id.x(), !dbg !20
  %tidf = uitofp i32 %tid to half, !dbg !21
  %val = fmul half %tidf, 2.0, !dbg !22
    #dbg_value(half %val, !19, !DIExpression(DIOpArg(0, half)), !22)
  store half %val, ptr addrspace(1) %out, align 2, !dbg !23
  ret void, !dbg !24
}

; Test 3: Idempotency — if the DIExpression already contains DIOpPushLane,
; getExpressionForDivergentDebugValue must NOT add a second set of lane ops.
; This tests the early-return guard at the top of the function.
; CHECK-LABEL: name: test_vgpr_dbg_value_existing_pushlane
; The expression must be preserved exactly as written — no second PushLane added.
; The closing "))" after DIOpByteOffset(i32) ensures the expression ends there;
; a doubled expression would have ", DIOpPushLane(...)" before the close.
; CHECK: DBG_VALUE %{{[0-9]+}}, $noreg, !{{[0-9]+}}, !DIExpression(DIOpArg(0, i32), DIOpPushLane(i32), DIOpConstant(i32 4), DIOpMul(), DIOpByteOffset(i32)), debug-location

define amdgpu_kernel void @test_vgpr_dbg_value_existing_pushlane(ptr addrspace(1) %out) #0 !dbg !26 {
entry:
  %tid = call i32 @llvm.amdgcn.workitem.id.x(), !dbg !29
  %val = shl i32 %tid, 2, !dbg !30
    #dbg_value(i32 %val, !28, !DIExpression(DIOpArg(0, i32), DIOpPushLane(i32), DIOpConstant(i32 4), DIOpMul(), DIOpByteOffset(i32)), !30)
  store i32 %val, ptr addrspace(1) %out, align 4, !dbg !31
  ret void, !dbg !32
}

declare i32 @llvm.amdgcn.workitem.id.x() #1

attributes #0 = { nounwind "target-features"="+wavefrontsize32" }
attributes #1 = { nounwind readnone speculatable }

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!3, !4}

!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: "clang", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug, enums: !2)
!1 = !DIFile(filename: "test_edge.cl", directory: "/tmp")
!2 = !{}
!3 = !{i32 7, !"Dwarf Version", i32 5}
!4 = !{i32 2, !"Debug Info Version", i32 3}

; Function 1: test_vgpr_dbg_value_i8
!5 = distinct !DISubprogram(name: "test_vgpr_dbg_value_i8", scope: !1, file: !1, line: 1, type: !6, isLocal: false, isDefinition: true, scopeLine: 1, flags: DIFlagPrototyped, isOptimized: false, unit: !0, retainedNodes: !8)
!6 = !DISubroutineType(types: !7)
!7 = !{null}
!8 = !{!9}
!9 = !DILocalVariable(name: "val8", scope: !5, file: !1, line: 2, type: !10)
!10 = !DIBasicType(name: "char", size: 8, encoding: DW_ATE_signed_char)
!11 = !DILocation(line: 1, column: 1, scope: !5)
!12 = !DILocation(line: 2, column: 1, scope: !5)
!13 = !DILocation(line: 3, column: 1, scope: !5)
!14 = !DILocation(line: 4, column: 1, scope: !5)
!15 = !DILocation(line: 5, column: 1, scope: !5)

; Function 2: test_vgpr_dbg_value_half
!16 = distinct !DISubprogram(name: "test_vgpr_dbg_value_half", scope: !1, file: !1, line: 10, type: !6, isLocal: false, isDefinition: true, scopeLine: 10, flags: DIFlagPrototyped, isOptimized: false, unit: !0, retainedNodes: !17)
!17 = !{!19}
!18 = !DIBasicType(name: "half", size: 16, encoding: DW_ATE_float)
!19 = !DILocalVariable(name: "valh", scope: !16, file: !1, line: 11, type: !18)
!20 = !DILocation(line: 10, column: 1, scope: !16)
!21 = !DILocation(line: 11, column: 1, scope: !16)
!22 = !DILocation(line: 12, column: 1, scope: !16)
!23 = !DILocation(line: 13, column: 1, scope: !16)
!24 = !DILocation(line: 14, column: 1, scope: !16)

; Function 3: test_vgpr_dbg_value_existing_pushlane (idempotency test)
!26 = distinct !DISubprogram(name: "test_vgpr_dbg_value_existing_pushlane", scope: !1, file: !1, line: 50, type: !6, isLocal: false, isDefinition: true, scopeLine: 50, flags: DIFlagPrototyped, isOptimized: false, unit: !0, retainedNodes: !27)
!27 = !{!28}
!28 = !DILocalVariable(name: "val_idempotent", scope: !26, file: !1, line: 51, type: !10)
!29 = !DILocation(line: 50, column: 1, scope: !26)
!30 = !DILocation(line: 51, column: 1, scope: !26)
!31 = !DILocation(line: 52, column: 1, scope: !26)
!32 = !DILocation(line: 53, column: 1, scope: !26)
