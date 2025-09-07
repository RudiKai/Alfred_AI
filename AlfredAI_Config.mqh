//+------------------------------------------------------------------+
//|                     AlfredAI_Config.mqh                          |
//|               Handles loading/saving of INI files                |
//|                   Copyright 2025, AlfredAI Project               |
//|                 https://github.com/rudikai/alfredai              |
//+------------------------------------------------------------------+
#ifndef ALFREDAI_CONFIG_MQH
#define ALFREDAI_CONFIG_MQH

#property strict

#include <Arrays/ArrayString.mqh>

//+------------------------------------------------------------------+
//| A simple INI-style configuration manager                         |
//+------------------------------------------------------------------+
class AAI_Config
  {
private:
   CArrayString *m_keys;
   CArrayString *m_values;
   string      m_path;

   //--- Custom trim function to avoid compiler issues
   void        Trim(string &str)
     {
      StringTrimLeft(str);
      StringTrimRight(str);
     }

public:
   //+------------------------------------------------------------------+
   //| Constructor                                                      |
   //+------------------------------------------------------------------+
               AAI_Config()
     {
      m_keys = new CArrayString();
      m_values = new CArrayString();
     }

   //+------------------------------------------------------------------+
   //| Destructor                                                       |
   //+------------------------------------------------------------------+
              ~AAI_Config()
     {
      delete m_keys;
      delete m_values;
     }

   //+------------------------------------------------------------------+
   //| Load configuration from a file                                   |
   //+------------------------------------------------------------------+
   bool        Load(const string path)
     {
      m_path = path;
      m_keys.Clear();
      m_values.Clear();

      int handle = FileOpen(m_path, FILE_READ|FILE_TXT, ';', CP_UTF8);
      if(handle == INVALID_HANDLE)
         return false; // File doesn't exist, will be created on Save

      while(!FileIsEnding(handle))
        {
         string line = FileReadString(handle);
         Trim(line);

         if(StringLen(line) == 0 || StringGetCharacter(line, 0) == '#')
            continue;

         int sep_pos = StringFind(line, "=");
         if(sep_pos > 0)
           {
            string key = StringSubstr(line, 0, sep_pos);
            string val = StringSubstr(line, sep_pos + 1);
            Trim(key);
            Trim(val);
            Set(key, val);
           }
        }
      FileClose(handle);
      return true;
     }

   //+------------------------------------------------------------------+
   //| Save configuration to a file                                     |
   //+------------------------------------------------------------------+
   bool        Save()
     {
      int handle = FileOpen(m_path, FILE_WRITE|FILE_TXT, ';', CP_UTF8);
      if(handle == INVALID_HANDLE)
         return false;

      for(int i = 0; i < m_keys.Total(); i++)
        {
         FileWriteString(handle, m_keys.At(i) + "=" + m_values.At(i) + "\n");
        }
      FileClose(handle);
      return true;
     }

   //+------------------------------------------------------------------+
   //| Get a string value                                               |
   //+------------------------------------------------------------------+
   string      Get(const string key, const string def = "")
     {
      long index = m_keys.Search(key);
      if(index != -1)
        {
         return m_values.At((int)index);
        }
      return def;
     }

   //+------------------------------------------------------------------+
   //| Get a double value                                               |
   //+------------------------------------------------------------------+
   double      GetD(const string key, double def = 0.0)
     {
      string val = Get(key, "");
      if(val != "")
         return StringToDouble(val);
      return def;
     }

   //+------------------------------------------------------------------+
   //| Get an integer value                                             |
   //+------------------------------------------------------------------+
   int         GetI(const string key, int def = 0)
     {
      string val = Get(key, "");
      if(val != "")
         return (int)StringToInteger(val);
      return def;
     }

   //+------------------------------------------------------------------+
   //| Set a value                                                      |
   //+------------------------------------------------------------------+
   bool        Set(const string key, const string val)
     {
      long index = m_keys.Search(key);
      if(index != -1)
        {
         m_values.Update((int)index, val);
        }
      else
        {
         m_keys.Add(key);
         m_values.Add(val);
        }
      return true;
     }
  };

#endif // ALFREDAI_CONFIG_MQH

