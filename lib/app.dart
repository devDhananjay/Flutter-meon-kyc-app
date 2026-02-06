import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:meon_kyc/config/env_config.dart';
import 'package:meon_kyc/pages/home_page.dart';
import 'package:meon_kyc/pages/page_not_found.dart';
import 'package:meon_kyc/pages/webview_page.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

class MeonKycApp extends StatelessWidget {
  const MeonKycApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Meon KYC',
      debugShowCheckedModeBanner: false,
      theme: KycTheme.theme,
      routerConfig: GoRouter(
        initialLocation: '/${EnvConfig.companyName}/${EnvConfig.workflowName}',
        routes: [
          GoRoute(
            path: '/:company/:workflowName',
            builder: (context, state) {
              final company = state.pathParameters['company'] ?? '';
              final workflow = state.pathParameters['workflowName'] ?? '';
              if (company.isEmpty || workflow.isEmpty) {
                return const PageNotFound();
              }
              // Pass query params from redirect URL to HomePage
              final queryParams = state.uri.queryParameters;
              return HomePage(
                company: company,
                workflowName: workflow,
                queryParams: queryParams,
              );
            },
          ),
          GoRoute(
            path: '/:company/:workflowName/webview',
            builder: (context, state) {
              final company = state.pathParameters['company'] ?? '';
              final workflow = state.pathParameters['workflowName'] ?? '';
              final url = state.uri.queryParameters['url'] ?? '';
              final title = state.uri.queryParameters['title'] ?? 'External Verification';
              if (company.isEmpty || workflow.isEmpty || url.isEmpty) {
                return const PageNotFound();
              }
              return WebViewPage(
                url: url,
                title: title,
                company: company,
                workflowName: workflow,
              );
            },
          ),
          GoRoute(
            path: '/404',
            builder: (context, state) => const PageNotFound(),
          ),
        ],
        errorBuilder: (context, state) => const PageNotFound(),
        redirect: (context, state) {
          final path = state.uri.path;
          if (path == '/' || path.isEmpty) {
            return '/${EnvConfig.companyName}/${EnvConfig.workflowName}';
          }
          return null;
        },
      ),
    );
  }
}
