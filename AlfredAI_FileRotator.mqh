//+------------------------------------------------------------------+
//|                   AlfredAI_FileRotator.mqh                       |
//|         Encapsulates file handle and rotation logic              |
//|                   Copyright 2025, AlfredAI Project               |
//|                 https://github.com/rudikai/alfredai              |
//+------------------------------------------------------------------+
#ifndef ALFREDAI_FILEROTATOR_MQH
#define ALFREDAI_FILEROTATOR_MQH

#property strict

#include "AlfredAI_Utils.mqh"

//+------------------------------------------------------------------+
//| Manages a log file with automatic size-based rotation.           |
//+------------------------------------------------------------------+
class AAI_FileRotator
  {
private:
   string m_base_path;
   long   m_max_bytes;
   int    m_max_backups;
   int    m_handle;

public:
   //+------------------------------------------------------------------+
   //| Constructor                                                      |
   //+------------------------------------------------------------------+
            AAI_FileRotator() : m_max_bytes(0), m_max_backups(0), m_handle(INVALID_HANDLE)
     {
     }

   //+------------------------------------------------------------------+
   //| Destructor                                                       |
   //+------------------------------------------------------------------+
           ~AAI_FileRotator()
     {
      Close();
     }

   //+------------------------------------------------------------------+
   //| Open the log file for writing.                                   |
   //+------------------------------------------------------------------+
   bool     Open(const string base_path, long max_bytes, int max_backups)
     {
      if(m_handle != INVALID_HANDLE)
         Close();

      m_base_path = base_path;
      m_max_bytes = max_bytes;
      m_max_backups = max_backups;

      //--- Check for rotation before opening
      if(AAI::FileRotate(m_base_path, m_max_backups, m_max_bytes))
        {
         PrintFormat("FileRotator: Log file %s rotated.", m_base_path);
        }

      m_handle = FileOpen(m_base_path, FILE_WRITE|FILE_TXT|FILE_SHARE_READ, ';', CP_UTF8);
      if(m_handle == INVALID_HANDLE)
        {
         PrintFormat("FileRotator: Failed to open file %s. Error: %d", m_base_path, GetLastError());
         return false;
        }
      FileSeek(m_handle, 0, SEEK_END);
      return true;
     }

   //+------------------------------------------------------------------+
   //| Write a line to the log file.                                    |
   //+------------------------------------------------------------------+
   bool     WriteLine(const string line)
     {
      if(m_handle == INVALID_HANDLE)
         return false;

      FileWriteString(m_handle, line + "\n");
      FileFlush(m_handle);
      return true;
     }

   //+------------------------------------------------------------------+
   //| Close the file handle.                                           |
   //+------------------------------------------------------------------+
   void     Close()
     {
      if(m_handle != INVALID_HANDLE)
        {
         FileClose(m_handle);
         m_handle = INVALID_HANDLE;
        }
     }

   //+------------------------------------------------------------------+
   //| Get the current path of the log file.                            |
   //+------------------------------------------------------------------+
   string   CurrentPath()
     {
      return m_base_path;
     }
  };

#endif // ALFREDAI_FILEROTATOR_MQH

