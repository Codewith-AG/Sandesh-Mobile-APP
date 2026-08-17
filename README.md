# Sandesh Mobile App

![Platform](https://img.shields.io/badge/Platform-Android-green?logo=android)
![Flutter](https://img.shields.io/badge/Flutter-3.5+-02569B?logo=flutter)
![Supabase](https://img.shields.io/badge/Backend-Supabase-3ECF8E?logo=supabase)

Sandesh is a modern, cross-platform messaging application built with **Flutter** (optimized for Android). It provides secure 1:1 and group chats, voice and video calling, rich media sharing, and features a completely self-hosted in-app update system.

## 📥 Download the App

You can download the latest compiled APK for Android from our dedicated releases repository:  
👉 **[Download Latest Sandesh Release](https://github.com/Codewith-AG/Sandesh-Releases/releases/latest)**

## 🚀 Key Features

*   **1:1 and Group Chat:** Real-time messaging with read and delivery receipts.
*   **Voice & Video Calls:** High-quality voice and video calls powered by Agora RTC.
*   **Guaranteed Notifications:** A custom 4-layer notification delivery system utilizing Supabase Realtime, Firebase Cloud Messaging (FCM), and verified backstops to ensure you never miss a message.
*   **Media Sharing:** Share images, videos, and files seamlessly, complete with on-device compression and Supabase Storage.
*   **In-App Updates:** A self-hosted over-the-air (OTA) update system that downloads and installs the latest APK automatically via the `Sandesh-Releases` repository.
*   **Offline Support:** Messages are locally cached using `sqflite` so your chat history is always accessible.

## 🛠️ Tech Stack

*   **Client Frontend:** Flutter & Dart (SDK 3.5+)
*   **Backend & Database:** [Supabase](https://supabase.com/) (PostgreSQL 17, Auth, Realtime, Storage)
*   **Edge Functions:** Deno-based Supabase Edge Functions for token minting and push notification fallbacks.
*   **Push Notifications:** Firebase Cloud Messaging (FCM) & `flutter_local_notifications`
*   **Real-time Communication (RTC):** [Agora](https://www.agora.io/en/)

## 🏗️ Architecture Overview

The application relies on Supabase for the heavy lifting of state and data management. 
*   **Authentication:** Users authenticate via Google or phone number. Identities map to a secure `profiles` table.
*   **Messaging Pipeline:** Messages are written to the cloud and stored locally. A combination of Realtime channels and background FCM isolates handles receiving messages when the app is in the foreground or killed.
*   **Security:** Full Row Level Security (RLS) is implemented on the Postgres database to ensure users can only access their own chats and groups.
*   **Calls:** Call signaling routes through the database and FCM, while the actual stream connects directly via Agora using tokens minted by a backend edge function.

## 📁 Repository Structure
*   `sandesh/lib/models/` — Data models (Messages, Groups, Contacts, Updates)
*   `sandesh/lib/screens/` — UI screens (Chat, Calls, Settings, Media Viewer, etc.)
*   `sandesh/lib/services/` — Business logic and backend interaction (Supabase Broadcast, Call Service, Media Upload, OTA Updates)
*   `supabase/functions/` — Backend edge functions (`send-push`, `agora-token`, `renotify`)
*   `supabase/migrations/` — Database schema definitions and RLS policies

## 🌟 About the Project

Sandesh is built to be a powerful and secure **alternative to WhatsApp**, providing all the essential features you expect from a modern messaging platform in an open and flexible ecosystem.

### 🤝 Collaborate with us!
If you're interested in collaborating on this project, have ideas for new features, or just want to chat about it, feel free to reach out! 

📧 **Contact:** codewithag@gmail.com

---
*Built with ❤️ by Codewith-AG*
