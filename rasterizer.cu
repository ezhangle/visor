#include "precompiled.h"
#include "gpu.h"
#include <cuda_runtime.h>

uint32_t GetIndex(const GPUState &state, uint32_t vertexIndex, bool indexed)
{
  if(!indexed)
    return vertexIndex;

  const byte *ib = state.ib.buffer->bytes + state.ib.offset;

  if(state.ib.indexType == VK_INDEX_TYPE_UINT16)
  {
    uint16_t *i16 = (uint16_t *)ib;
    i16 += vertexIndex;
    return *i16;
  }
  else
  {
    uint32_t *i32 = (uint32_t *)ib;
    i32 += vertexIndex;
    return *i32;
  }
}

static void ShadeVerts(const GPUState &state, int numVerts, uint32_t first, bool indexed,
                       std::vector<VertexCacheEntry> &out)
{
  MICROPROFILE_SCOPE(rasterizer_ShadeVerts);

  VertexCacheEntry tri[4];

  if(state.pipeline->topology == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST)
  {
    VertexCacheEntry vert;

    // only handle whole triangles
    int lastVert = numVerts - 3;
    uint32_t vertexIndex = first;

    for(int v = 0; v <= lastVert; v += 3)
    {
      state.pipeline->vs(state, GetIndex(state, vertexIndex, indexed), tri[0]);
      vertexIndex++;
      state.pipeline->vs(state, GetIndex(state, vertexIndex, indexed), tri[1]);
      vertexIndex++;
      state.pipeline->vs(state, GetIndex(state, vertexIndex, indexed), tri[2]);
      vertexIndex++;

      out.push_back(tri[0]);
      out.push_back(tri[1]);
      out.push_back(tri[2]);
    }
  }
  else if(state.pipeline->topology == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP)
  {
    assert(numVerts >= 3);

    // strip order to preserve winding order is:
    // N+0, N+1, N+2
    // N+2, N+1, N+3
    // N+2, N+3, N+4
    // N+4, N+5, N+6
    // ...
    //
    // So each pair of triangles forms the same pattern, we alternate between one and the other.
    // Bear in mind that the strip might end after the first half of a pair so we can't just shade
    // all 4 verts:
    //
    // N+0, N+1, N+2
    // N+2, N+1, N+3
    // M = N+2
    // M+0, M+1, M+2
    // M+2, M+1, M+3
    // S = M+2
    // S+0, S+1, S+2
    // S+2, S+1, S+3

    // do the first one separately when we have to emit a whole triangle
    uint32_t vertexIndex = first;

    state.pipeline->vs(state, GetIndex(state, vertexIndex, indexed), tri[0]);
    vertexIndex++;
    state.pipeline->vs(state, GetIndex(state, vertexIndex, indexed), tri[1]);
    vertexIndex++;
    state.pipeline->vs(state, GetIndex(state, vertexIndex, indexed), tri[2]);
    vertexIndex++;

    out.push_back(tri[0]);
    out.push_back(tri[1]);
    out.push_back(tri[2]);

    numVerts -= 3;

    if(numVerts > 0)
    {
      state.pipeline->vs(state, GetIndex(state, vertexIndex, indexed), tri[3]);
      vertexIndex++;
      numVerts--;

      out.push_back(tri[2]);
      out.push_back(tri[1]);
      out.push_back(tri[3]);
    }

    while(numVerts > 0)
    {
      // pull in two re-used verts from previous run.
      // See above:
      //
      // M = N+2
      // M+0, M+1, M+2
      //
      // so M+0 = N+2, M+1 = N+3
      tri[0] = tri[2];
      tri[1] = tri[3];

      state.pipeline->vs(state, GetIndex(state, vertexIndex, indexed), tri[2]);
      vertexIndex++;
      numVerts--;

      out.push_back(tri[0]);
      out.push_back(tri[1]);
      out.push_back(tri[2]);

      if(numVerts > 0)
      {
        state.pipeline->vs(state, GetIndex(state, vertexIndex, indexed), tri[3]);
        vertexIndex++;
        numVerts--;

        out.push_back(tri[2]);
        out.push_back(tri[1]);
        out.push_back(tri[3]);
      }
    }
  }
  else
  {
    printf("Unsupported primitive topology!\n");
  }
}

static void ToWindow(uint32_t w, uint32_t h, const std::vector<VertexCacheEntry> &pos,
                     std::vector<int4> &out)
{
  MICROPROFILE_SCOPE(rasterizer_ToWindow);

  for(const VertexCacheEntry &v : pos)
  {
    int4 win = make_int4(0, 0, 0, 0);

    win.x = int((v.position.x / v.position.w + 1.0f) * 0.5f * w);
    win.y = int((v.position.y * -1.0f / v.position.w + 1.0f) * 0.5f * h);

    out.push_back(win);
  }
}

static void MinMax(const int4 *coords, int4 &minwin, int4 &maxwin)
{
  MICROPROFILE_SCOPE(rasterizer_MinMax);

  minwin = {INT_MAX, INT_MAX, INT_MAX, INT_MAX};
  maxwin = {INT_MIN, INT_MIN, INT_MIN, INT_MIN};

  for(int i = 0; i < 3; i++)
  {
    //for(int c = 0; c < 4; c++)
    {
      minwin.x = std::min(minwin.x, coords[i].x);
      maxwin.x = std::max(maxwin.x, coords[i].x);
      minwin.y = std::min(minwin.y, coords[i].y);
      maxwin.y = std::max(maxwin.y, coords[i].y);
      minwin.z = std::min(minwin.z, coords[i].z);
      maxwin.z = std::max(maxwin.z, coords[i].z);
      minwin.w = std::min(minwin.w, coords[i].w);
      maxwin.w = std::max(maxwin.w, coords[i].w);
    }
  }
}

static int double_triarea(const int4 &a, const int4 &b, const int4 &c)
{
  return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

static float clamp01(float in)
{
  return in > 1.0f ? 1.0f : (in < 0.0f ? 0.0f : in);
}

static inline int4 barycentric(const int ABx, const int ABy, const int ACx, const int ACy,
                               const int area2, const int4 *verts, const int4 &pixel)
{
  /*

  static int4 cross(int4 a, int4 b)
  {
    return int4((a.y * b.z) - (b.y * a.z), (a.z * b.x) - (b.z * a.x), (a.x * b.y) - (b.x * a.y), 1);
  }

  int4 u = cross(int4(verts[1].x - verts[0].x, verts[2].x - verts[0].x, verts[0].x - pixel.x, 1),
                 int4(verts[1].y - verts[0].y, verts[2].y - verts[0].y, verts[0].y - pixel.y, 1));

  if(u.z == 0)
    return int4(-1, -1, -1, -1);

  return int4(u.z - (u.x + u.y), u.x, u.y, u.z);

  */

  const int PAx = verts[0].x - pixel.x;
  const int PAy = verts[0].y - pixel.y;

  const int ux = (ACx * PAy) - (ACy * PAx);
  const int uy = (PAx * ABy) - (PAy * ABx);

  return make_int4(area2 - (ux + uy), ux, uy, 0);
}

void ClearTarget(VkImage target, const VkClearDepthStencilValue &col)
{
  MICROPROFILE_SCOPE(rasterizer_ClearTarget);

  byte *bits = target->pixels;
  const uint32_t w = target->extent.width;
  const uint32_t h = target->extent.height;
  const uint32_t bpp = target->bytesPerPixel;

  assert(bpp == 4);

  for(uint32_t y = 0; y < h; y++)
  {
    for(uint32_t x = 0; x < w; x++)
    {
      memcpy(&bits[(y * w + x) * 4], &col.depth, 4);
    }
  }
}

void ClearTarget(VkImage target, const VkClearColorValue &col)
{
  MICROPROFILE_SCOPE(rasterizer_ClearTarget);

  byte *bits = target->pixels;
  const uint32_t w = target->extent.width;
  const uint32_t h = target->extent.height;
  const uint32_t bpp = target->bytesPerPixel;

  byte eval[4];
  eval[2] = byte(col.float32[0] * 255.0f);
  eval[1] = byte(col.float32[1] * 255.0f);
  eval[0] = byte(col.float32[2] * 255.0f);
  eval[3] = byte(col.float32[3] * 255.0f);

  if(bpp == 1)
  {
    memset(bits, eval[2], w * h);
  }
  else if(bpp == 4)
  {
    for(uint32_t y = 0; y < h; y++)
    {
      for(uint32_t x = 0; x < w; x++)
      {
        memcpy(&bits[(y * w + x) * bpp], eval, 4);
      }
    }
  }
}

void DrawTriangles(const GPUState &state, int numVerts, uint32_t first, bool indexed)
{
  MICROPROFILE_SCOPE(rasterizer_DrawTriangles);

  byte *bits = state.col[0]->pixels;
  const uint32_t w = state.col[0]->extent.width;
  const uint32_t h = state.col[0]->extent.height;
  const uint32_t bpp = state.col[0]->bytesPerPixel;

  float *depthbits = state.depth ? (float *)state.depth->pixels : NULL;

  static std::vector<VertexCacheEntry> shadedVerts;
  shadedVerts.clear();
  ShadeVerts(state, numVerts, first, indexed, shadedVerts);

  static std::vector<int4> winCoords;
  winCoords.clear();
  ToWindow(w, h, shadedVerts, winCoords);

  int pixels_written = 0, pixels_tested = 0, depth_passed = 0;
  int tris_in = 0, tris_out = 0;

  const int4 *curTriangle = winCoords.data();
  const VertexCacheEntry *curVSOut = shadedVerts.data();

  assert(winCoords.size() % 3 == 0);

  for(int i = 0; i < winCoords.size(); i += 3)
  {
    const int4 *tri = curTriangle;
    const VertexCacheEntry *vsout = curVSOut;

    curTriangle += 3;
    curVSOut += 3;

    tris_in++;

    int area2 = double_triarea(tri[0], tri[1], tri[2]);

    // skip zero-area triangles
    if(area2 == 0)
      continue;

    int area2_flipped = area2;

    int barymul = 1;
    // if clockwise winding is front-facing, invert barycentrics and area before backface test
    if(state.pipeline->frontFace == VK_FRONT_FACE_CLOCKWISE)
    {
      barymul *= -1;
      area2_flipped *= -1;
    }

    // cull front-faces if desired
    if(area2_flipped > 0 && (state.pipeline->cullMode & VK_CULL_MODE_FRONT_BIT))
      continue;

    if(area2_flipped < 0)
    {
      // cull back-faces if desired
      if(state.pipeline->cullMode & VK_CULL_MODE_BACK_BIT)
        continue;

      // otherwise flip barycentrics again to ensure they'll be positive
      barymul *= -1;
      area2_flipped *= -1;
    }

    float invarea = 1.0f / float(area2_flipped);

    tris_out++;

    int4 minwin, maxwin;
    MinMax(tri, minwin, maxwin);

    float4 invw = make_float4(1.0f / vsout[0].position.w, 1.0f / vsout[1].position.w, 1.0f / vsout[2].position.w,
                0.0f);
    float4 depth = make_float4(vsout[0].position.z * invw.x, vsout[1].position.z * invw.y,
                 vsout[2].position.z * invw.z, 0.0f);

    // clamp to screen, assume guard band is enough!
    minwin.x = std::max(0, minwin.x);
    minwin.y = std::max(0, minwin.y);
    maxwin.x = std::min(int(w - 1), maxwin.x);
    maxwin.y = std::min(int(h - 1), maxwin.y);

    const int ABx = tri[1].x - tri[0].x;
    const int ABy = tri[1].y - tri[0].y;
    const int ACx = tri[2].x - tri[0].x;
    const int ACy = tri[2].y - tri[0].y;

    for(int y = minwin.y; y < maxwin.y; y++)
    {
      for(int x = minwin.x; x < maxwin.x; x++)
      {
        int4 b = barycentric(ABx, ABy, ACx, ACy, area2, tri, make_int4(x, y, 0, 0));

        b.x *= barymul;
        b.y *= barymul;
        b.z *= barymul;

        if(b.x >= 0 && b.y >= 0 && b.z >= 0)
        {
          // normalise the barycentrics
          float4 n = make_float4(float(b.x), float(b.y), float(b.z), 0.0f);
          n.x *= invarea;
          n.y *= invarea;
          n.z *= invarea;

          // calculate pixel depth
          float pixdepth = n.x * depth.x + n.y * depth.y + n.z * depth.z;

          bool passed = true;

          if(state.pipeline->depthCompareOp != VK_COMPARE_OP_ALWAYS && depthbits)
          {
            float curdepth = depthbits[y * w + x];

            switch(state.pipeline->depthCompareOp)
            {
              case VK_COMPARE_OP_NEVER: passed = false; break;
              case VK_COMPARE_OP_LESS: passed = pixdepth < curdepth; break;
              case VK_COMPARE_OP_EQUAL: passed = pixdepth == curdepth; break;
              case VK_COMPARE_OP_LESS_OR_EQUAL: passed = pixdepth <= curdepth; break;
              case VK_COMPARE_OP_GREATER: passed = pixdepth > curdepth; break;
              case VK_COMPARE_OP_NOT_EQUAL: passed = pixdepth != curdepth; break;
              case VK_COMPARE_OP_GREATER_OR_EQUAL: passed = pixdepth >= curdepth; break;
            }
          }

          if(passed)
          {
            // perspective correct with W
            n.x *= invw.x;
            n.y *= invw.y;
            n.z *= invw.z;

            float invlen = 1.0f / (n.x + n.y + n.z);
            n.x *= invlen;
            n.y *= invlen;
            n.z *= invlen;

            float4 pix;
            state.pipeline->fs(state, (const float)pixdepth, n, vsout, pix);

            if(state.pipeline->blend.blendEnable)
            {
              float4 existing = make_float4(bits[(y * w + x) * bpp + 2], bits[(y * w + x) * bpp + 1],
                                       bits[(y * w + x) * bpp + 0], 1.0f);
              existing.x /= 255.0f;
              existing.y /= 255.0f;
              existing.z /= 255.0f;

              float srcFactor = 1.0f;

              switch(state.pipeline->blend.srcColorBlendFactor)
              {
                case VK_BLEND_FACTOR_ZERO: srcFactor = 0.0f; break;
                case VK_BLEND_FACTOR_ONE: srcFactor = 1.0f; break;
                case VK_BLEND_FACTOR_SRC_ALPHA: srcFactor = pix.w; break;
                case VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA: srcFactor = 1.0f - pix.w; break;
                case VK_BLEND_FACTOR_SRC_COLOR:
                case VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR:
                case VK_BLEND_FACTOR_DST_COLOR:
                case VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR:
                case VK_BLEND_FACTOR_DST_ALPHA:
                case VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA:
                case VK_BLEND_FACTOR_CONSTANT_COLOR:
                case VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR:
                case VK_BLEND_FACTOR_CONSTANT_ALPHA:
                case VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_ALPHA:
                case VK_BLEND_FACTOR_SRC_ALPHA_SATURATE:
                case VK_BLEND_FACTOR_SRC1_COLOR:
                case VK_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR:
                case VK_BLEND_FACTOR_SRC1_ALPHA:
                case VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA:
                  printf("Unsupported blend factor\n");
                  break;
              }

              float dstFactor = 1.0f;

              switch(state.pipeline->blend.dstColorBlendFactor)
              {
                case VK_BLEND_FACTOR_ZERO: dstFactor = 0.0f; break;
                case VK_BLEND_FACTOR_ONE: dstFactor = 1.0f; break;
                case VK_BLEND_FACTOR_SRC_ALPHA: dstFactor = pix.w; break;
                case VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA: dstFactor = 1.0f - pix.w; break;
                case VK_BLEND_FACTOR_SRC_COLOR:
                case VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR:
                case VK_BLEND_FACTOR_DST_COLOR:
                case VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR:
                case VK_BLEND_FACTOR_DST_ALPHA:
                case VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA:
                case VK_BLEND_FACTOR_CONSTANT_COLOR:
                case VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR:
                case VK_BLEND_FACTOR_CONSTANT_ALPHA:
                case VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_ALPHA:
                case VK_BLEND_FACTOR_SRC_ALPHA_SATURATE:
                case VK_BLEND_FACTOR_SRC1_COLOR:
                case VK_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR:
                case VK_BLEND_FACTOR_SRC1_ALPHA:
                case VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA:
                  printf("Unsupported blend factor\n");
                  break;
              }

              float4 blended;

              switch(state.pipeline->blend.colorBlendOp)
              {
                case VK_BLEND_OP_ADD:
                  blended.x = srcFactor * pix.x + dstFactor * existing.x;
                  blended.y = srcFactor * pix.y + dstFactor * existing.y;
                  blended.z = srcFactor * pix.z + dstFactor * existing.z;
                  blended.w = srcFactor * pix.w + dstFactor * existing.w;
                  break;
                case VK_BLEND_OP_SUBTRACT:
                case VK_BLEND_OP_REVERSE_SUBTRACT:
                case VK_BLEND_OP_MIN:
                case VK_BLEND_OP_MAX: printf("Unsupported blend op\n"); break;
              }

              pix = blended;
            }

            bits[(y * w + x) * bpp + 2] = byte(clamp01(pix.x) * 255.0f);
            bits[(y * w + x) * bpp + 1] = byte(clamp01(pix.y) * 255.0f);
            bits[(y * w + x) * bpp + 0] = byte(clamp01(pix.z) * 255.0f);

            depth_passed++;

            if(state.pipeline->depthWriteEnable && depthbits)
            {
              depthbits[y * w + x] = pixdepth;
            }
          }

          pixels_written++;
        }

        pixels_tested++;
      }
    }
  }

  MICROPROFILE_COUNTER_ADD("rasterizer/pixels/tested", pixels_tested);
  MICROPROFILE_COUNTER_ADD("rasterizer/pixels/written", pixels_written);
  MICROPROFILE_COUNTER_ADD("rasterizer/depth/passed", depth_passed);
  MICROPROFILE_COUNTER_ADD("rasterizer/triangles/in", tris_in);
  MICROPROFILE_COUNTER_ADD("rasterizer/triangles/out", tris_out);
  MICROPROFILE_COUNTER_ADD("rasterizer/draws/in", 1);
}
