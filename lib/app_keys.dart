import 'package:flutter/material.dart';

/// 全局根导航器 Key。
///
/// 挂在 `MaterialApp.navigatorKey` 上，供"与页面无关的服务"弹出全屏页面使用 ——
/// 典型场景是人机验证弹窗：请求可能发生在任意页面、甚至非页面上下文里。
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
