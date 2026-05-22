// Copyright 2019 The Flutter team. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';

class NewSocialPage extends StatelessWidget {
  const NewSocialPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.facebook), text: 'Facebook'),
              Tab(icon: Icon(Icons.person), text: 'Instagram'),
              Tab(icon: Icon(Icons.person), text: 'Twitter'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    children: [
                      SizedBox(
                        width: 225,
                        height: 48,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.facebook),
                          label: const Text("Login with Facebook"),
                          onPressed: null,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    children: [
                      SizedBox(
                        width: 225,
                        height: 48,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.person),
                          label: const Text("Login with Instagram"),
                          onPressed: null,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    children: [
                      SizedBox(
                        width: 225,
                        height: 48,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.person),
                          label: const Text("Login with Twitter"),
                          onPressed: null,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
