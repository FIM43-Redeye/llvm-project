; RUN: llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -O0 -stop-after=finalize-isel < %s | FileCheck %s

; Test that DBG_VALUE instructions for divergent values (VGPRs) get the
; lane-specific byte offset operations added to their DIExpression.
; This is needed for correct debug info in SIMT execution model where
; each lane has its own value in the VGPR.

; CHECK-LABEL: name: test_vgpr_dbg_value
; CHECK: DBG_VALUE %{{[0-9]+}}, $noreg, !{{[0-9]+}}, !DIExpression(DIOpArg(0, i32), DIOpPushLane(i32), DIOpConstant(i32 4), DIOpMul(), DIOpByteOffset(i32))

define amdgpu_kernel void @test_vgpr_dbg_value(ptr addrspace(1) %out) #0 !dbg !5 {
entry:
  %tid = call i32 @llvm.amdgcn.workitem.id.x(), !dbg !11
  %val = shl i32 %tid, 2, !dbg !12
    #dbg_value(i32 %val, !9, !DIExpression(DIOpArg(0, i32)), !12)
  store i32 %val, ptr addrspace(1) %out, align 4, !dbg !13
  ret void, !dbg !14
}

; A 64-bit value occupies two VGPR_32s, so the lane offset cannot be applied
; here: it must be applied to each register piece independently, which is only
; known once the value is split across registers. The expression is therefore
; left unchanged at ISel and the per-register lane offset is emitted later by
; DwarfExpression (verified in dbg-value-vgpr-lane-offset-dwarf.ll).
; CHECK-LABEL: name: test_vgpr_dbg_value_i64
; CHECK: DBG_VALUE %{{[0-9]+}}, $noreg, !{{[0-9]+}}, !DIExpression(DIOpArg(0, i64)), debug-location

define amdgpu_kernel void @test_vgpr_dbg_value_i64(ptr addrspace(1) %out) #0 !dbg !15 {
entry:
  %tid = call i32 @llvm.amdgcn.workitem.id.x(), !dbg !19
  %tid64 = zext i32 %tid to i64, !dbg !20
  %val = shl i64 %tid64, 2, !dbg !21
    #dbg_value(i64 %val, !18, !DIExpression(DIOpArg(0, i64)), !21)
  store i64 %val, ptr addrspace(1) %out, align 8, !dbg !22
  ret void, !dbg !23
}

; Test that SGPR (uniform) values do NOT get lane-specific operations
; CHECK-LABEL: name: test_sgpr_dbg_value
; CHECK: DBG_VALUE %{{[0-9]+}}, $noreg, !{{[0-9]+}}, !DIExpression(DIOpArg(0, i32)), debug-location

define amdgpu_kernel void @test_sgpr_dbg_value(ptr addrspace(1) %out, i32 %uniform_val) #0 !dbg !25 {
entry:
  %val = add i32 %uniform_val, 1, !dbg !29
    #dbg_value(i32 %val, !28, !DIExpression(DIOpArg(0, i32)), !29)
  store i32 %val, ptr addrspace(1) %out, align 4, !dbg !30
  ret void, !dbg !31
}

; Test with i16 type - lane stride is 4 bytes (VGPR_32 register width),
; not 2 bytes (type size), because i16 occupies a full 32-bit VGPR lane.
; CHECK-LABEL: name: test_vgpr_dbg_value_i16
; CHECK: DBG_VALUE %{{[0-9]+}}, $noreg, !{{[0-9]+}}, !DIExpression(DIOpArg(0, i16), DIOpPushLane(i32), DIOpConstant(i32 4), DIOpMul(), DIOpByteOffset(i16))

define amdgpu_kernel void @test_vgpr_dbg_value_i16(ptr addrspace(1) %out) #0 !dbg !33 {
entry:
  %tid = call i32 @llvm.amdgcn.workitem.id.x(), !dbg !38
  %tid16 = trunc i32 %tid to i16, !dbg !39
  %val = shl i16 %tid16, 1, !dbg !40
    #dbg_value(i16 %val, !36, !DIExpression(DIOpArg(0, i16)), !40)
  store i16 %val, ptr addrspace(1) %out, align 2, !dbg !41
  ret void, !dbg !42
}

; Test with DIOpFragment - lane offset operations should be inserted before Fragment
; Use a 64-bit variable with a 32-bit fragment to avoid "fragment covers entire variable" error
; CHECK-LABEL: name: test_vgpr_dbg_value_with_fragment
; CHECK: DBG_VALUE %{{[0-9]+}}, $noreg, !{{[0-9]+}}, !DIExpression(DIOpArg(0, i32), DIOpPushLane(i32), DIOpConstant(i32 4), DIOpMul(), DIOpByteOffset(i32), DIOpFragment(0, 32))

define amdgpu_kernel void @test_vgpr_dbg_value_with_fragment(ptr addrspace(1) %out) #0 !dbg !44 {
entry:
  %tid = call i32 @llvm.amdgcn.workitem.id.x(), !dbg !49
  %val = shl i32 %tid, 2, !dbg !50
    #dbg_value(i32 %val, !47, !DIExpression(DIOpArg(0, i32), DIOpFragment(0, 32)), !50)
  store i32 %val, ptr addrspace(1) %out, align 4, !dbg !51
  ret void, !dbg !52
}

; Test with old-format DIExpression (DWARF ops) - should NOT be modified
; CHECK-LABEL: name: test_old_diexpression
; CHECK: DBG_VALUE %{{[0-9]+}}, $noreg, !{{[0-9]+}}, !DIExpression(), debug-location

define amdgpu_kernel void @test_old_diexpression(ptr addrspace(1) %out) #0 !dbg !54 {
entry:
  %tid = call i32 @llvm.amdgcn.workitem.id.x(), !dbg !59
  %val = shl i32 %tid, 2, !dbg !60
    #dbg_value(i32 %val, !57, !DIExpression(), !60)
  store i32 %val, ptr addrspace(1) %out, align 4, !dbg !61
  ret void, !dbg !62
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

; Function 1: test_vgpr_dbg_value
!5 = distinct !DISubprogram(name: "test_vgpr_dbg_value", scope: !1, file: !1, line: 1, type: !6, isLocal: false, isDefinition: true, scopeLine: 1, flags: DIFlagPrototyped, isOptimized: false, unit: !0, retainedNodes: !8)
!6 = !DISubroutineType(types: !7)
!7 = !{null}
!8 = !{!9}
!9 = !DILocalVariable(name: "val", scope: !5, file: !1, line: 2, type: !10)
!10 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!11 = !DILocation(line: 1, column: 1, scope: !5)
!12 = !DILocation(line: 2, column: 1, scope: !5)
!13 = !DILocation(line: 3, column: 1, scope: !5)
!14 = !DILocation(line: 4, column: 1, scope: !5)

; Function 2: test_vgpr_dbg_value_i64 (multi-register: expression left unchanged at ISel)
!15 = distinct !DISubprogram(name: "test_vgpr_dbg_value_i64", scope: !1, file: !1, line: 10, type: !6, isLocal: false, isDefinition: true, scopeLine: 10, flags: DIFlagPrototyped, isOptimized: false, unit: !0, retainedNodes: !16)
!16 = !{!18}
!17 = !DIBasicType(name: "long", size: 64, encoding: DW_ATE_signed)
!18 = !DILocalVariable(name: "val64", scope: !15, file: !1, line: 11, type: !17)
!19 = !DILocation(line: 10, column: 1, scope: !15)
!20 = !DILocation(line: 11, column: 1, scope: !15)
!21 = !DILocation(line: 12, column: 1, scope: !15)
!22 = !DILocation(line: 13, column: 1, scope: !15)
!23 = !DILocation(line: 14, column: 1, scope: !15)

; Function 3: test_sgpr_dbg_value (uniform/SGPR value - should NOT have lane offset)
!25 = distinct !DISubprogram(name: "test_sgpr_dbg_value", scope: !1, file: !1, line: 30, type: !6, isLocal: false, isDefinition: true, scopeLine: 30, flags: DIFlagPrototyped, isOptimized: false, unit: !0, retainedNodes: !26)
!26 = !{!28}
!27 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!28 = !DILocalVariable(name: "val", scope: !25, file: !1, line: 31, type: !27)
!29 = !DILocation(line: 31, column: 1, scope: !25)
!30 = !DILocation(line: 32, column: 1, scope: !25)
!31 = !DILocation(line: 33, column: 1, scope: !25)

; Function 4: test_vgpr_dbg_value_i16
!33 = distinct !DISubprogram(name: "test_vgpr_dbg_value_i16", scope: !1, file: !1, line: 40, type: !6, isLocal: false, isDefinition: true, scopeLine: 40, flags: DIFlagPrototyped, isOptimized: false, unit: !0, retainedNodes: !34)
!34 = !{!36}
!35 = !DIBasicType(name: "short", size: 16, encoding: DW_ATE_signed)
!36 = !DILocalVariable(name: "val16", scope: !33, file: !1, line: 41, type: !35)
!38 = !DILocation(line: 40, column: 1, scope: !33)
!39 = !DILocation(line: 41, column: 1, scope: !33)
!40 = !DILocation(line: 42, column: 1, scope: !33)
!41 = !DILocation(line: 43, column: 1, scope: !33)
!42 = !DILocation(line: 44, column: 1, scope: !33)

; Function 5: test_vgpr_dbg_value_with_fragment (64-bit variable with 32-bit fragment)
!44 = distinct !DISubprogram(name: "test_vgpr_dbg_value_with_fragment", scope: !1, file: !1, line: 50, type: !6, isLocal: false, isDefinition: true, scopeLine: 50, flags: DIFlagPrototyped, isOptimized: false, unit: !0, retainedNodes: !45)
!45 = !{!47}
!46 = !DIBasicType(name: "long", size: 64, encoding: DW_ATE_signed)
!47 = !DILocalVariable(name: "valfrag", scope: !44, file: !1, line: 51, type: !46)
!49 = !DILocation(line: 50, column: 1, scope: !44)
!50 = !DILocation(line: 51, column: 1, scope: !44)
!51 = !DILocation(line: 52, column: 1, scope: !44)
!52 = !DILocation(line: 53, column: 1, scope: !44)

; Function 6: test_old_diexpression (uses old format DIExpression)
!54 = distinct !DISubprogram(name: "test_old_diexpression", scope: !1, file: !1, line: 60, type: !6, isLocal: false, isDefinition: true, scopeLine: 60, flags: DIFlagPrototyped, isOptimized: false, unit: !0, retainedNodes: !55)
!55 = !{!57}
!56 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!57 = !DILocalVariable(name: "valold", scope: !54, file: !1, line: 61, type: !56)
!59 = !DILocation(line: 60, column: 1, scope: !54)
!60 = !DILocation(line: 61, column: 1, scope: !54)
!61 = !DILocation(line: 62, column: 1, scope: !54)
!62 = !DILocation(line: 63, column: 1, scope: !54)
